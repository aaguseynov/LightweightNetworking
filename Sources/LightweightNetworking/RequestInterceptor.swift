import Foundation

// MARK: - RequestInterceptor

public protocol RequestInterceptor: Sendable {
    func adapt(_ request: URLRequest) async throws -> URLRequest
    func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision
}


// MARK: - RetryDecision

public enum RetryDecision: Sendable {
    case doNotRetry
    case retry
    case retryAfter(TimeInterval)
}

// MARK: - Default Implementation

extension RequestInterceptor {
    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        request
    }
    
    public func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision {
        .doNotRetry
    }
}
