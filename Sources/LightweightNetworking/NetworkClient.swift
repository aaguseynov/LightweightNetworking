import Foundation

// MARK: - NetworkClient

public actor NetworkClient: NetworkService {
    // MARK: - Properties
    
    private let session: URLSession
    private let interceptor: RequestInterceptor?
    private let plugins: [NetworkPlugin]
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var activeTasks: [UUID: URLSessionTask] = [:]
    private var retryAttempts: [String: Int] = [:]
    private let maxRetryAttempts: Int
    
    // MARK: - Initialization
    
    public init(
        configuration: URLSessionConfiguration = .default,
        interceptor: RequestInterceptor? = nil,
        plugins: [NetworkPlugin] = [],
        decoder: JSONDecoder = .defaultDecoder,
        encoder: JSONEncoder = .defaultEncoder,
        maxRetryAttempts: Int = 3
    ) {
        self.session = URLSession(configuration: configuration)
        self.interceptor = interceptor
        self.plugins = plugins
        self.decoder = decoder
        self.encoder = encoder
        self.maxRetryAttempts = maxRetryAttempts
    }
    
    // MARK: - NetworkService
    
    public func request<E: Endpoint>(_ endpoint: E, taskId: UUID = UUID()) async throws -> E.Response {
        let requestKey = "\(endpoint.baseURL.absoluteString)\(endpoint.path)"
        let currentRetryCount = retryAttempts[requestKey] ?? 0
        
        do {
            // Build request
            var urlRequest = try buildRequest(from: endpoint)
            
            // Adapt request through interceptor
            if let interceptor = interceptor {
                urlRequest = try await interceptor.adapt(urlRequest)
            }
            
            // Make immutable copy for async context
            let finalRequest = urlRequest
            
            // Notify plugins
            await notifyPlugins { await $0.willSend(request: finalRequest) }
            
            // Perform request
            let (data, response) = try await performRequest(finalRequest, taskId: taskId)
            
            // Validate response
            try ResponseValidator.validate(response, data: data)
            
            // Handle empty response
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 204 || data.isEmpty {
                if E.Response.self == EmptyResponse.self {
                    retryAttempts.removeValue(forKey: requestKey)
                    
                    let result: Result<(Data, URLResponse), Error> = .success((data, response))
                    await notifyPlugins { await $0.didReceive(result: result, for: finalRequest) }
                    
                    return EmptyResponse() as! E.Response
                }
            }
            
            // Decode response
            let decodedResponse: E.Response
            do {
                decodedResponse = try decoder.decode(E.Response.self, from: data)
            } catch {
                throw NetworkError.decodingError(error.localizedDescription)
            }
            
            // Success - clear retry attempts
            retryAttempts.removeValue(forKey: requestKey)
            
            // Notify plugins
            let result: Result<(Data, URLResponse), Error> = .success((data, response))
            await notifyPlugins { await $0.didReceive(result: result, for: finalRequest) }
            
            return decodedResponse
            
        } catch let error as NetworkError {
            // Build request for error handling
            let errorRequest = try buildRequest(from: endpoint)
            
            // Notify plugins about error
            await notifyPluginsError(error, for: errorRequest)
            
            // Check if should retry
            if let interceptor = interceptor,
               currentRetryCount < maxRetryAttempts {
                
                let decision = await interceptor.retry(error, for: errorRequest, retryCount: currentRetryCount)
                
                switch decision {
                case .retry:
                    retryAttempts[requestKey] = currentRetryCount + 1
                    return try await request(endpoint, taskId: taskId)
                    
                case .retryAfter(let delay):
                    retryAttempts[requestKey] = currentRetryCount + 1
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    return try await request(endpoint, taskId: taskId)
                    
                case .doNotRetry:
                    retryAttempts.removeValue(forKey: requestKey)
                    throw error
                }
            }
            
            retryAttempts.removeValue(forKey: requestKey)
            throw error
            
        } catch {
            let networkError = NetworkError.underlying(error)
            let errorRequest = try buildRequest(from: endpoint)
            await notifyPluginsError(networkError, for: errorRequest)
            retryAttempts.removeValue(forKey: requestKey)
            throw networkError
        }
    }
    
    public func cancelRequest(taskId: UUID) async {
        activeTasks[taskId]?.cancel()
        activeTasks.removeValue(forKey: taskId)
    }
    
    public func cancelAllRequests() async {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
        retryAttempts.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func buildRequest<E: Endpoint>(from endpoint: E) throws -> URLRequest {
        // Build URL with path
        var url = endpoint.baseURL.appendingPathComponent(endpoint.path)
        
        // Add query parameters
        if let query = endpoint.query, !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            
            guard let finalURL = components?.url else {
                throw NetworkError.invalidURL
            }
            url = finalURL
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = endpoint.timeout
        
        // Add headers
        endpoint.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Add body
        if let body = endpoint.body {
            do {
                request.httpBody = try encodeBody(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } catch {
                throw NetworkError.encodingError(error.localizedDescription)
            }
        }
        
        return request
    }
    
    private func encodeBody(_ body: any Encodable) throws -> Data {
        // Кодируем body в корень JSON без обёртки, чтобы API получал { "identity_token": "...", ... }
        struct RootEncodable: Encodable {
            let body: any Encodable
            func encode(to encoder: Encoder) throws {
                try body.encode(to: encoder)
            }
        }
        return try encoder.encode(RootEncodable(body: body))
    }
    
    private func performRequest(_ request: URLRequest, taskId: UUID) async throws -> (Data, URLResponse) {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error {
                        if (error as NSError).code == NSURLErrorCancelled {
                            continuation.resume(throwing: NetworkError.cancelled)
                        } else if (error as NSError).code == NSURLErrorTimedOut {
                            continuation.resume(throwing: NetworkError.timeout)
                        } else {
                            continuation.resume(throwing: NetworkError.underlying(error))
                        }
                        return
                    }
                    
                    guard let data = data, let response = response else {
                        continuation.resume(throwing: NetworkError.noData)
                        return
                    }
                    
                    continuation.resume(returning: (data, response))
                }
                
                activeTasks[taskId] = task
                task.resume()
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(taskId: taskId)
            }
        }
    }
    
    private func notifyPlugins(_ action: @Sendable (NetworkPlugin) async -> Void) async {
        for plugin in plugins {
            await action(plugin)
        }
    }
    
    private func notifyPluginsError(_ error: NetworkError, for request: URLRequest) async {
        let result: Result<(Data, URLResponse), Error> = .failure(error)
        await notifyPlugins { await $0.didReceive(result: result, for: request) }
    }
}

// MARK: - JSONDecoder + JSONEncoder Extensions

public extension JSONDecoder {
    static var defaultDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

public extension JSONEncoder {
    static var defaultEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
