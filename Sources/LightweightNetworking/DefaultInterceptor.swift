import Foundation

public actor DefaultInterceptor: RequestInterceptor {
    private let tokenProvider: @Sendable () async throws -> String?
    private let refreshTokenProvider: (@Sendable () async throws -> String?)?
    private let maxRetries: Int
    private let retryPolicy: RetryPolicy?
    private let recovery = RefreshCoordinator()
    private var replacement: (old: String, new: String)?
    private var epoch = UUID()
    @TaskLocal private static var isRefreshRequest = false

    public init(
        tokenProvider: @escaping @Sendable () async throws -> String?,
        refreshTokenProvider: (@Sendable () async throws -> String?)? = nil,
        maxRetries: Int = 1,
        retryPolicy: RetryPolicy? = nil
    ) {
        precondition(maxRetries >= 0, "Retry count must be nonnegative")
        self.tokenProvider = tokenProvider
        self.refreshTokenProvider = refreshTokenProvider
        self.maxRetries = maxRetries
        self.retryPolicy = retryPolicy
    }

    public func prepare(_ request: URLRequest, authorization: AuthorizationRequirement) async throws -> PreparedRequest {
        if case .none = authorization {
            var request = request
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            return PreparedRequest(request: request)
        }
        let prepared = try await prepare(request)
        if case .required = authorization {
            guard prepared.request.value(forHTTPHeaderField: "Authorization")?.isEmpty == false else { throw NetworkError.unauthorized }
        }
        return prepared
    }

    public func prepare(_ request: URLRequest) async throws -> PreparedRequest {
        let session = epoch
        let version = await recovery.generation
        let adapted = try await adapt(request)
        guard session == epoch else { throw NetworkError.cancelled }
        return PreparedRequest(request: adapted, refreshGeneration: version, sessionEpoch: session)
    }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        guard !Self.isRefreshRequest else { return request }
        var request = request
        if let token = try await currentToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    public func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision {
        let prepared = PreparedRequest(request: request, refreshGeneration: await recovery.generation, sessionEpoch: epoch)
        return await retry(error, for: prepared, retryCount: retryCount)
    }

    public func retry(_ error: NetworkError, for prepared: PreparedRequest, retryCount: Int) async -> RetryDecision {
        guard !Task.isCancelled else { return .doNotRetry }
        if let session = prepared.sessionEpoch, session != epoch { return .fail(.cancelled) }
        if !error.isAuthenticationError {
            return await retryPolicy?.retry(error, for: prepared.request, retryCount: retryCount) ?? .doNotRetry
        }
        guard !Self.isRefreshRequest, retryCount < maxRetries,
              let refreshTokenProvider, prepared.sessionEpoch == epoch,
              let version = prepared.refreshGeneration,
              let sent = prepared.request.value(forHTTPHeaderField: "Authorization"), sent.hasPrefix("Bearer ") else {
            return .doNotRetry
        }
        do {
            guard let current = try await currentToken() else { return .doNotRetry }
            if sent != "Bearer \(current)" { return .retry }
            let session = epoch
            try await recovery.run(since: version) { [self] in
                try await Self.$isRefreshRequest.withValue(true) {
                    try await refresh(using: refreshTokenProvider, previousToken: current, session: session)
                }
            }
            if session != epoch { return .fail(.cancelled) }
            return Task.isCancelled ? .doNotRetry : .retry
        } catch {
            if prepared.sessionEpoch != epoch { return .fail(.cancelled) }
            let failure = NetworkError.normalizing(error)
            return failure == .unauthorized ? .doNotRetry : .fail(failure)
        }
    }

    /// Reset recovery before replacing credentials on logout or account changes.
    public func reset() async {
        epoch = UUID()
        replacement = nil
        await recovery.reset()
    }

    private func currentToken() async throws -> String? {
        let session = epoch
        let token = try await tokenProvider()
        guard session == epoch else { throw NetworkError.cancelled }
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { replacement = nil; return nil }
        if let replacement, replacement.old == token { return replacement.new }
        replacement = nil
        return token
    }

    private func refresh(using provider: @Sendable () async throws -> String?, previousToken: String, session: UUID) async throws {
        guard let token = try await provider(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.unauthorized
        }
        try Task.checkCancellation()
        let stored = try await tokenProvider()
        guard session == epoch, let stored else { throw NetworkError.unauthorized }
        let effective = replacement?.old == stored ? replacement?.new : stored
        guard effective == previousToken || stored == token else { throw NetworkError.unauthorized }
        replacement = stored == token ? nil : (stored, token)
    }
}
