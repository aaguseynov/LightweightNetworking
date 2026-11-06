import Foundation

public actor NetworkClient: NetworkService {
    private let session: URLSession
    private let interceptor: (any RequestInterceptor)?
    private let plugins: [any NetworkPlugin]
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let maxRetryAttempts: Int
    private let resourceTimeout: TimeInterval?

    // Tasks have different response types; cancellation is the only erased operation.
    private var operations: [UUID: @Sendable () -> Void] = [:]
    var activeRequestCount: Int { operations.count }

    /// - Parameter resourceTimeout: Optional total operation budget in seconds. Includes preparation,
    ///   transport, recovery and retries. Expiry cancels cooperatively and returns `.timeout`.
    public init(
        configuration: URLSessionConfiguration = .default,
        interceptor: (any RequestInterceptor)? = nil,
        plugins: [any NetworkPlugin] = [],
        decoder: JSONDecoder = .defaultDecoder,
        encoder: JSONEncoder = .defaultEncoder,
        maxRetryAttempts: Int = 3,
        resourceTimeout: TimeInterval? = nil
    ) {
        precondition(maxRetryAttempts >= 0, "Retry count must be nonnegative")
        if let resourceTimeout {
            precondition(resourceTimeout.isFinite && resourceTimeout > 0 && resourceTimeout <= Double(Int64.max) / 1_000_000_000,
                         "Resource timeout must be finite, positive, and representable")
        }
        self.session = URLSession(configuration: configuration)
        self.interceptor = interceptor
        self.plugins = plugins
        self.decoder = decoder
        self.encoder = encoder
        self.maxRetryAttempts = maxRetryAttempts
        self.resourceTimeout = resourceTimeout
    }

    deinit { session.invalidateAndCancel() }

    public func request<E: Endpoint>(_ endpoint: E, taskId: UUID = UUID()) async throws -> E.Response {
        guard operations[taskId] == nil else { throw NetworkError.duplicateTaskID }
        // Capture one monotonic deadline at acceptance, not once per HTTP attempt.
        let deadline = resourceTimeout.map { ContinuousClock.now.advanced(by: .seconds($0)) }
        // An owned task is necessary for cancellation by ID. Its lifetime is bounded by this call.
        let task = Task { try await executeWithinDeadline(endpoint, deadline: deadline) }
        operations[taskId] = { task.cancel() }
        defer {
            task.cancel()
            operations.removeValue(forKey: taskId)
        }

        do {
            return try await withTaskCancellationHandler {
                try checkBudget(deadline)
                let result = try await task.value
                guard !task.isCancelled else { throw NetworkError.cancelled }
                try checkBudget(deadline)
                return result
            } onCancel: {
                task.cancel()
            }
        } catch {
            if Task.isCancelled || task.isCancelled { throw NetworkError.cancelled }
            if let deadline, ContinuousClock.now >= deadline { throw NetworkError.timeout }
            throw NetworkError.normalizing(error)
        }
    }

    public func cancelRequest(taskId: UUID) async { operations[taskId]?() }

    public func cancelAllRequests() async {
        operations.values.forEach { $0() }
    }

    private func executeWithinDeadline<E: Endpoint>(
        _ endpoint: E, deadline: ContinuousClock.Instant?
    ) async throws -> E.Response {
        guard let deadline else { return try await execute(endpoint, deadline: nil) }
        try checkBudget(deadline)
        return try await withThrowingTaskGroup(of: E.Response.self) { group in
            group.addTask { [self] in
                let value = try await execute(endpoint, deadline: deadline)
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw NetworkError.timeout }
                return value
            }
            group.addTask {
                try await ContinuousClock().sleep(until: deadline)
                try Task.checkCancellation()
                throw NetworkError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw NetworkError.cancelled }
            return value
        }
    }

    private func checkBudget(_ deadline: ContinuousClock.Instant?) throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw NetworkError.timeout }
    }

    private func execute<E: Endpoint>(_ endpoint: E, deadline: ContinuousClock.Instant?) async throws -> E.Response {
        try checkBudget(deadline)
        let original = try buildRequest(from: endpoint)
        var retryCount = 0

        while true {
            try checkBudget(deadline)
            var prepared = PreparedRequest(request: original)
            do {
                if let interceptor { prepared = try await interceptor.prepare(original, authorization: endpoint.authorization) }
                if case .none = endpoint.authorization {
                    var anonymous = prepared.request
                    anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
                    prepared = PreparedRequest(request: anonymous)
                }
                let request = prepared.request
                if interceptor == nil, case .required = endpoint.authorization,
                   request.value(forHTTPHeaderField: "Authorization")?.isEmpty != false { throw NetworkError.unauthorized }
                try checkBudget(deadline)
                for plugin in plugins {
                    await plugin.willSend(request: request)
                    try checkBudget(deadline)
                }
                let (data, response) = try await session.data(for: request)
                try checkBudget(deadline)
                try ResponseValidator.validate(response, data: data)

                let decoded: E.Response
                if E.Response.self == EmptyResponse.self, data.isEmpty || (response as? HTTPURLResponse)?.statusCode == 204 {
                    decoded = EmptyResponse() as! E.Response
                } else {
                    guard !data.isEmpty else { throw NetworkError.noData }
                    do { decoded = try decoder.decode(E.Response.self, from: data) }
                    catch { throw NetworkError.decodingError(error.localizedDescription) }
                }
                try checkBudget(deadline)
                await notify(.success((data, response)), for: request)
                return decoded
            } catch {
                let failure = NetworkError.normalizing(error)
                await notify(.failure(failure), for: prepared.request)
                try checkBudget(deadline)
                guard failure != .cancelled, !Task.isCancelled,
                      retryCount < maxRetryAttempts, let interceptor else { throw failure }
                let decision = await interceptor.retry(failure, for: prepared, retryCount: retryCount)
                try checkBudget(deadline)
                switch decision {
                case .doNotRetry: throw failure
                case .fail(let finalError): throw finalError
                case .retry: break
                case .retryAfter(let delay):
                    // Reject invalid interceptor input rather than trapping during Double conversion.
                    guard delay.isFinite, delay >= 0, delay <= Double(Int64.max) / 1_000_000_000 else { throw failure }
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                retryCount += 1
            }
        }
    }

    private func buildRequest<E: Endpoint>(from endpoint: E) throws -> URLRequest {
        let url = endpoint.baseURL.appendingPathComponent(endpoint.path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw NetworkError.invalidURL }
        if let query = endpoint.query {
            components.queryItems = (components.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let finalURL = components.url else { throw NetworkError.invalidURL }
        var request = URLRequest(url: finalURL)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = endpoint.timeout
        endpoint.headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body = endpoint.body {
            do { request.httpBody = try encoder.encode(body) }
            catch { throw NetworkError.encodingError(error.localizedDescription) }
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    private func notify(_ result: Result<(Data, URLResponse), Error>, for request: URLRequest) async {
        for plugin in plugins { await plugin.didReceive(result: result, for: request) }
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
