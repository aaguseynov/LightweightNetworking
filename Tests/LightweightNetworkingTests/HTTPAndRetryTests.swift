import Foundation
import Testing
@testable import LightweightNetworking

@Suite
struct HTTPAndRetryTests {
    private func request(_ method: String = "GET", key: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://example.invalid")!)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        return request
    }
    private func delay(_ decision: RetryDecision) -> Double? {
        if case .retryAfter(let value) = decision { return value }
        return nil
    }

    @Test func httpErrorRetainsStatusHeadersAndBody() {
        for code in [401, 408, 429, 504] {
            let body = Data("error".utf8)
            let response = HTTPURLResponse(url: request().url!, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "7", "X-Request-ID": "request-id"])!
            do { try ResponseValidator.validate(response, data: body); Issue.record("Error response accepted") }
            catch let error as NetworkError {
                #expect(error.statusCode == code)
                #expect(error.responseHeaders["retry-after"] == "7")
                #expect(error.responseData == body)
                #expect(error.isAuthenticationError == (code == 401))
                #expect(error != .timeout)
            } catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func boundedExponentialBackoffAndJitter() {
        let policy = RetryPolicy(maxRetries: 4, baseDelay: 1, maxDelay: 3, jitter: false)
        for (count, expected) in [1.0, 2.0, 3.0, 3.0].enumerated() {
            #expect(delay(policy.decision(.timeout, request: request(), retryCount: count, now: Date(), unitRandom: 1)) == expected)
        }
        #expect(delay(policy.decision(.timeout, request: request(), retryCount: 4, now: Date(), unitRandom: 1)) == nil)
        let jitter = RetryPolicy(baseDelay: 2, maxDelay: 3)
        #expect(delay(jitter.decision(.timeout, request: request(), retryCount: 0, now: Date(), unitRandom: 0.25)) == 0.5)
    }

    @Test func unsafeMethodsRequireAnExplicitIdempotencyKey() {
        let policy = RetryPolicy(jitter: false)
        for method in ["POST", "PATCH"] {
            #expect(delay(policy.decision(.timeout, request: request(method), retryCount: 0, now: Date(), unitRandom: 1)) == nil)
            #expect(delay(policy.decision(.timeout, request: request(method, key: "unique-operation"), retryCount: 0, now: Date(), unitRandom: 1)) != nil)
        }
    }

    @Test func retryAfterRespectsServerMinimumAndBudget() {
        let policy = RetryPolicy(maxDelay: 10, jitter: false)
        let now = Date(timeIntervalSince1970: 0)
        for raw in ["7", "Thu, 01 Jan 1970 00:00:07 GMT"] {
            let failure = NetworkError.http(HTTPFailure(statusCode: 429, headers: ["Retry-After": raw]))
            #expect(delay(policy.decision(failure, request: request(), retryCount: 0, now: now, unitRandom: 1)) == 7)
        }
        let tooLong = NetworkError.http(HTTPFailure(statusCode: 503, headers: ["Retry-After": "120"]))
        #expect(delay(policy.decision(tooLong, request: request(), retryCount: 0, now: now, unitRandom: 1)) == nil)
    }

    @Test func cancellationValidationAndUnauthorizedAreNotTransient() {
        let policy = RetryPolicy()
        for error in [NetworkError.cancelled, .unauthorized, .decodingError("invalid"), .http(HTTPFailure(statusCode: 422))] {
            #expect(delay(policy.decision(error, request: request(), retryCount: 0, now: Date(), unitRandom: 1)) == nil)
        }
    }
}
