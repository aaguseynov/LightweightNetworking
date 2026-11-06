import Foundation
import Testing
@testable import LightweightNetworking

private final class DeadlineState: @unchecked Sendable {
    // All mutable fixture state is protected by the lock; no production unsafe conformance is used.
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var failures = 0
    private var failureStatus = 500
    private var decodingCount = 0

    func reset(failures: Int = 0, status: Int = 500) {
        lock.lock(); defer { lock.unlock() }
        counts = [:]; self.failures = failures; failureStatus = status; decodingCount = 0
    }
    func next(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        counts[path, default: 0] += 1
        return counts[path, default: 0] <= failures ? failureStatus : 200
    }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    func decoded() { lock.lock(); defer { lock.unlock() }; decodingCount += 1 }
    func decodings() -> Int { lock.lock(); defer { lock.unlock() }; return decodingCount }
}

private final class DeadlineProtocol: URLProtocol, @unchecked Sendable {
    static let state = DeadlineState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.state.next(request.url!.path)
        if request.url!.path.hasPrefix("/blocked") { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { _ = Self.state.next("stopped") }
}

private struct DeadlineValue: Decodable, Sendable { let ok: Bool }
private struct DeadlineEndpoint: Endpoint {
    typealias Response = DeadlineValue
    typealias Body = Never
    let baseURL = URL(string: "https://deadline.invalid")!
    let method = HTTPMethod.get
    var path = "/fast"
    var authorization = AuthorizationRequirement.none
}
private struct SlowDecoderEndpoint: Endpoint {
    struct Response: Decodable, Sendable {
        init(from decoder: Decoder) throws {
            DeadlineProtocol.state.decoded()
            // Intentionally synchronous to verify the post-decoding budget check.
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
    typealias Body = Never
    let baseURL = URL(string: "https://deadline.invalid")!
    let method = HTTPMethod.get
    let path = "/decode"
}
private struct WaitingAdapter: RequestInterceptor {
    let duration: Duration
    func adapt(_ request: URLRequest) async throws -> URLRequest {
        try await Task.sleep(for: duration)
        return request
    }
}
private struct DelayedRetry: RequestInterceptor {
    let delay: TimeInterval
    func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision { .retryAfter(delay) }
}
private actor RefreshGate {
    var entered = false
    var entryWaiters: [CheckedContinuation<Void, Never>] = []
    var release: CheckedContinuation<Void, Never>?
    var calls = 0
    func pause() async throws -> String {
        calls += 1; entered = true
        let previous = entryWaiters; entryWaiters.removeAll(); previous.forEach { $0.resume() }
        await withCheckedContinuation { release = $0 }
        try Task.checkCancellation()
        return "fresh"
    }
    func wait() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func open() { release?.resume(); release = nil }
}

@Suite(.serialized)
struct DeadlineTests {
    private func config() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeadlineProtocol.self]
        return configuration
    }
    private func expectFailure(_ error: NetworkError, from task: Task<DeadlineValue, Error>) async {
        do { _ = try await task.value; Issue.record("Expected \(error)") }
        catch let actual as NetworkError { #expect(actual == error) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
    private func waitForRequest(_ path: String) async {
        let end = ContinuousClock.now + .seconds(2)
        while DeadlineProtocol.state.count(path) == 0, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(DeadlineProtocol.state.count(path) == 1)
    }

    @Test func fastRequestCompletesAndCancelsItsTimer() async throws {
        DeadlineProtocol.state.reset()
        let client = NetworkClient(configuration: config(), resourceTimeout: 2)
        #expect(try await client.request(DeadlineEndpoint()).ok)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func failureBeforeDeadlineKeepsItsOriginalError() async {
        DeadlineProtocol.state.reset(failures: 1, status: 422)
        let client = NetworkClient(configuration: config(), resourceTimeout: 2)
        do { _ = try await client.request(DeadlineEndpoint()); Issue.record("HTTP failure should propagate") }
        catch { #expect((error as? NetworkError)?.statusCode == 422) }
        #expect(await client.activeRequestCount == 0)
    }

    @Test func absentDeadlineKeepsExistingBehavior() async throws {
        DeadlineProtocol.state.reset()
        let client = NetworkClient(configuration: config(), interceptor: WaitingAdapter(duration: .milliseconds(100)))
        #expect(try await client.request(DeadlineEndpoint()).ok)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func deadlineIncludesAsyncPreparation() async {
        DeadlineProtocol.state.reset()
        let client = NetworkClient(configuration: config(), interceptor: WaitingAdapter(duration: .seconds(30)), resourceTimeout: 0.2)
        await expectFailure(.timeout, from: Task { try await client.request(DeadlineEndpoint()) })
        #expect(DeadlineProtocol.state.count("/fast") == 0)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func deadlineIncludesTokenProvider() async {
        DeadlineProtocol.state.reset()
        let interceptor = DefaultInterceptor(tokenProvider: {
            try await Task.sleep(for: .seconds(30))
            return "token"
        })
        let client = NetworkClient(configuration: config(), interceptor: interceptor, resourceTimeout: 0.2)
        await expectFailure(.timeout, from: Task { try await client.request(DeadlineEndpoint(authorization: .required)) })
        #expect(DeadlineProtocol.state.count("/fast") == 0)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func deadlineCancelsActiveTransport() async {
        DeadlineProtocol.state.reset()
        let client = NetworkClient(configuration: config(), resourceTimeout: 0.2)
        await expectFailure(.timeout, from: Task { try await client.request(DeadlineEndpoint(path: "/blocked")) })
        #expect(DeadlineProtocol.state.count("/blocked") == 1)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func deadlineIncludesBackoffWithoutSendingAgain() async {
        DeadlineProtocol.state.reset(failures: 1)
        let client = NetworkClient(configuration: config(), interceptor: DelayedRetry(delay: 10), resourceTimeout: 0.2)
        await expectFailure(.timeout, from: Task { try await client.request(DeadlineEndpoint()) })
        #expect(DeadlineProtocol.state.count("/fast") == 1)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func retryDoesNotRestartTheBudget() async {
        DeadlineProtocol.state.reset(failures: 2)
        let client = NetworkClient(configuration: config(), interceptor: DelayedRetry(delay: 0.25), resourceTimeout: 0.4)
        await expectFailure(.timeout, from: Task { try await client.request(DeadlineEndpoint()) })
        #expect(DeadlineProtocol.state.count("/fast") == 2)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func resultDecodedAfterDeadlineIsNotReturned() async {
        DeadlineProtocol.state.reset()
        let client = NetworkClient(configuration: config(), resourceTimeout: 0.2)
        do { _ = try await client.request(SlowDecoderEndpoint()); Issue.record("Late decoded result returned") }
        catch { #expect(error as? NetworkError == .timeout) }
        #expect(DeadlineProtocol.state.decodings() == 1)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func explicitIDCancellationIsNotReportedAsTimeout() async {
        DeadlineProtocol.state.reset()
        let client = NetworkClient(configuration: config(), resourceTimeout: 5)
        let id = UUID()
        let task = Task { try await client.request(DeadlineEndpoint(path: "/blocked"), taskId: id) }
        await waitForRequest("/blocked")
        await client.cancelRequest(taskId: id)
        await expectFailure(.cancelled, from: task)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func parentCancellationIsNotReportedAsTimeout() async {
        DeadlineProtocol.state.reset()
        let client = NetworkClient(configuration: config(), resourceTimeout: 5)
        let task = Task { try await client.request(DeadlineEndpoint(path: "/blocked")) }
        await waitForRequest("/blocked")
        task.cancel()
        await expectFailure(.cancelled, from: task)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func deadlineOfOneOperationDoesNotCancelAnother() async {
        DeadlineProtocol.state.reset()
        let client = NetworkClient(configuration: config(), resourceTimeout: 0.3)
        let first = Task { try await client.request(DeadlineEndpoint(path: "/blocked-first")) }
        await waitForRequest("/blocked-first")
        try? await Task.sleep(for: .milliseconds(150))
        let second = Task { try await client.request(DeadlineEndpoint(path: "/blocked-second")) }
        await waitForRequest("/blocked-second")
        await expectFailure(.timeout, from: first)
        await expectFailure(.timeout, from: second)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func deadlineCancelsOnlyItsOwnRefreshWaiter() async throws {
        DeadlineProtocol.state.reset(failures: 1, status: 401)
        let gate = RefreshGate()
        let interceptor = DefaultInterceptor(tokenProvider: { "old" }, refreshTokenProvider: { try await gate.pause() })
        let longClient = NetworkClient(configuration: config(), interceptor: interceptor, resourceTimeout: 3)
        let shortClient = NetworkClient(configuration: config(), interceptor: interceptor, resourceTimeout: 0.2)
        let long = Task { try await longClient.request(DeadlineEndpoint(path: "/long", authorization: .required)) }
        await gate.wait()
        let short = Task { try await shortClient.request(DeadlineEndpoint(path: "/short", authorization: .required)) }
        await expectFailure(.timeout, from: short)
        await gate.open()
        #expect(try await long.value.ok)
        #expect(await gate.calls == 1)
        #expect(DeadlineProtocol.state.count("/long") == 2)
        #expect(DeadlineProtocol.state.count("/short") == 1)
        #expect(await longClient.activeRequestCount == 0)
        #expect(await shortClient.activeRequestCount == 0)
    }
}
