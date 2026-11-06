import Foundation

// MARK: - RequestInterceptor

public protocol RequestInterceptor: Sendable {
    func prepare(_ request: URLRequest, authorization: AuthorizationRequirement) async throws -> PreparedRequest
    func prepare(_ request: URLRequest) async throws -> PreparedRequest
    func retry(_ error: NetworkError, for prepared: PreparedRequest, retryCount: Int) async -> RetryDecision
    func adapt(_ request: URLRequest) async throws -> URLRequest
    func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision
}


// MARK: - RetryDecision

public enum RetryDecision: Sendable {
    case doNotRetry
    /// Stop and propagate a failure from recovery instead of misreporting the original HTTP error.
    case fail(NetworkError)
    case retry
    case retryAfter(TimeInterval)
}

// MARK: - Default Implementation

extension RequestInterceptor {
    /// Default policy targets the standard Authorization header. Override for other credential schemes.
    public func prepare(_ request: URLRequest, authorization: AuthorizationRequirement) async throws -> PreparedRequest {
        var prepared = try await prepare(request)
        switch authorization {
        case .none:
            var request = prepared.request
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            prepared = PreparedRequest(request: request)
        case .required:
            guard let value = prepared.request.value(forHTTPHeaderField: "Authorization"), !value.isEmpty else {
                throw NetworkError.unauthorized
            }
        case .ifAvailable: break
        }
        return prepared
    }

    public func prepare(_ request: URLRequest) async throws -> PreparedRequest {
        PreparedRequest(request: try await adapt(request))
    }

    public func retry(_ error: NetworkError, for prepared: PreparedRequest, retryCount: Int) async -> RetryDecision {
        await retry(error, for: prepared.request, retryCount: retryCount)
    }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        request
    }
    
    public func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision {
        .doNotRetry
    }
}
