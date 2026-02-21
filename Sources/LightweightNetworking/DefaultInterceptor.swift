import Foundation

// MARK: - DefaultInterceptor

public actor DefaultInterceptor: RequestInterceptor {
    private let tokenProvider: @Sendable () async throws -> String?
    private let refreshTokenProvider: (@Sendable () async throws -> String?)?
    private var isRefreshing = false
    private var refreshTask: Task<Void, Error>?
    private let maxRetries: Int
    
    public init(
        tokenProvider: @escaping @Sendable () async throws -> String?,
        refreshTokenProvider: (@Sendable () async throws -> String?)? = nil,
        maxRetries: Int = 1
    ) {
        self.tokenProvider = tokenProvider
        self.refreshTokenProvider = refreshTokenProvider
        self.maxRetries = maxRetries
    }
    
    // MARK: - RequestInterceptor
    
    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        var mutableRequest = request
        
        if let token = try await tokenProvider() {
            mutableRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        return mutableRequest
    }
    
    public func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision {
        guard error.isAuthenticationError,
              let refreshTokenProvider = refreshTokenProvider,
              retryCount < maxRetries else {
            return .doNotRetry
        }
        
        if let task = refreshTask {
            do {
                try await task.value
                return .retry
            } catch {
                return .doNotRetry
            }
        }
        
        if !isRefreshing {
            isRefreshing = true
            
            refreshTask = Task {
                defer {
                    isRefreshing = false
                    refreshTask = nil
                }
                
                _ = try await refreshTokenProvider()
            }
            
            do {
                try await refreshTask?.value
                return .retry
            } catch {
                return .doNotRetry
            }
        }
        
        return .doNotRetry
    }
}
