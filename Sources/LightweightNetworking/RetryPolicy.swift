import Foundation

/// Opt-in retries for transient failures. Defaults never replay unprotected POST/PATCH requests.
public struct RetryPolicy: RequestInterceptor {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitter: Bool

    public init(maxRetries: Int = 2, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 30, jitter: Bool = true) {
        precondition(maxRetries >= 0 && baseDelay.isFinite && maxDelay.isFinite && baseDelay >= 0 && maxDelay >= baseDelay)
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    public func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision {
        decision(error, request: request, retryCount: retryCount, now: Date(), unitRandom: Double.random(in: 0...1))
    }

    func decision(_ error: NetworkError, request: URLRequest, retryCount: Int, now: Date, unitRandom: Double) -> RetryDecision {
        guard retryCount >= 0, retryCount < maxRetries else { return .doNotRetry }
        let safeMethod = ["GET", "HEAD", "OPTIONS", "PUT", "DELETE"].contains(request.httpMethod ?? "GET")
        let hasKey = !(request.value(forHTTPHeaderField: "Idempotency-Key")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard safeMethod || hasKey else { return .doNotRetry }
        let retryable: Bool
        switch error {
        case .timeout: retryable = true
        case .underlying(let underlying):
            let code = (underlying as? URLError)?.code
            retryable = code == .networkConnectionLost || code == .cannotConnectToHost
        default: retryable = [408, 429, 500, 502, 503, 504].contains(error.statusCode ?? 0)
        }
        guard retryable else { return .doNotRetry }
        let backoff = min(maxDelay, baseDelay * pow(2, min(30, Double(retryCount))))
        var delay = jitter ? backoff * min(1, max(0, unitRandom)) : backoff
        if let raw = error.responseHeaders["retry-after"], let minimum = retryAfter(raw, now: now) {
            // Never retry earlier than the server permits, or wait beyond the configured budget.
            guard minimum <= maxDelay else { return .doNotRetry }
            delay = max(delay, minimum)
        }
        return .retryAfter(delay)
    }

    private func retryAfter(_ value: String, now: Date) -> TimeInterval? {
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
