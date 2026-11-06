import Foundation
import Testing
@testable import LightweightNetworking

private final class LockedState: @unchecked Sendable {
    // Every access to mutable state is protected by lock.
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var failFirst = false
    private var failureStatus = 500
    private var authorizations: [String?] = []

    func reset(failFirst: Bool, status: Int = 500) { lock.lock(); defer { lock.unlock() }; counts = [:]; self.failFirst = failFirst; failureStatus = status; authorizations = [] }
    func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; authorizations.append(request.value(forHTTPHeaderField: "Authorization")) }
    func sentAuthorizations() -> [String?] { lock.lock(); defer { lock.unlock() }; return authorizations }
    func count(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[id, default: 0] }
    func next(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        counts[id, default: 0] += 1
        return failFirst && counts[id] == 1 ? failureStatus : 200
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let state = LockedState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "unspecified"
        Self.state.record(request)
        let status = Self.state.next(id)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor Gate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func signal() { entered = true; enteredWaiter?.resume(); enteredWaiter = nil }
    func pause() async { signal(); await withCheckedContinuation { release = $0 } }
    func open() { release?.resume(); release = nil }
}

private struct ResultBody: Decodable, Sendable { let ok: Bool }
private struct NoBody: Encodable, Sendable {}
private struct TestEndpoint: Endpoint {
    typealias Response = ResultBody
    let baseURL = URL(string: "https://audit.invalid")!
    let path = "/same"
    let method = HTTPMethod.get
    let id: String
    let authorization = AuthorizationRequirement.ifAvailable
    var body: NoBody? = nil
    var query: [String: String]? { ["id": id] }
}

private actor PausedRetryInterceptor: RequestInterceptor {
    let gate: Gate
    var aAdaptations = 0
    init(gate: Gate) { self.gate = gate }
    func adapt(_ request: URLRequest) async throws -> URLRequest {
        if request.url!.query!.contains("id=A") {
            aAdaptations += 1
            if aAdaptations == 2 { await gate.pause() }
        }
        return request
    }
    func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision { .retry }
}

private actor BackoffInterceptor: RequestInterceptor {
    let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision {
        await gate.signal()
        return .retryAfter(0.3)
    }
}

@Suite(.serialized)
struct NetworkClientTests {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return config
    }

    @Test func finishedTasksShouldBeRemoved() async throws {
        StubProtocol.state.reset(failFirst: false)
        let client = NetworkClient(configuration: configuration())
        for i in 0..<3 { _ = try await client.request(TestEndpoint(id: String(i))) }
        let retained = await client.activeRequestCount
        #expect(retained == 0)
    }

    @Test func eachConcurrentRequestShouldHaveItsOwnRetryBudget() async {
        StubProtocol.state.reset(failFirst: true)
        let gate = Gate()
        let client = NetworkClient(configuration: configuration(), interceptor: PausedRetryInterceptor(gate: gate), maxRetryAttempts: 1)
        let first = Task { try await client.request(TestEndpoint(id: "A")) }
        await gate.waitUntilEntered()
        var secondSucceeded = false
        do { secondSucceeded = try await client.request(TestEndpoint(id: "B")).ok }
        catch { Issue.record("Second concurrent request failed: \(error)") }
        await gate.open()
        _ = try? await first.value
        #expect(secondSucceeded)
        #expect(StubProtocol.state.count("B") == 2)
    }

    @Test func cancelByIDShouldStopBackoffAndRetry() async {
        StubProtocol.state.reset(failFirst: true)
        let gate = Gate()
        let client = NetworkClient(configuration: configuration(), interceptor: BackoffInterceptor(gate: gate), maxRetryAttempts: 1)
        let id = UUID()
        let task = Task { try await client.request(TestEndpoint(id: "cancel"), taskId: id) }
        await gate.waitUntilEntered()
        await client.cancelRequest(taskId: id)
        var cancelled = false
        do { _ = try await task.value }
        catch let error as NetworkError { cancelled = error == .cancelled }
        catch { cancelled = error is CancellationError }
        #expect(cancelled)
        #expect(StubProtocol.state.count("cancel") == 1)
    }

    private actor TokenStore {
        var token = "old"
        var refreshes = 0
        func current() -> String { token }
        func refresh() -> String {
            refreshes += 1
            token = "new-\(refreshes)"
            return token
        }
        func count() -> Int { refreshes }
    }

    @Test func lateUnauthorizedForOldTokenShouldReuseFreshToken() async throws {
        let store = TokenStore()
        let interceptor = DefaultInterceptor(
            tokenProvider: { await store.current() },
            refreshTokenProvider: { await store.refresh() }
        )
        let base = URLRequest(url: URL(string: "https://audit.invalid")!)
        // Both requests were sent with the old token before the first refresh.
        let first = try await interceptor.adapt(base)
        let second = try await interceptor.adapt(base)
        _ = await interceptor.retry(.unauthorized, for: first, retryCount: 0)
        // Its 401 arrives after the first refresh has completed.
        _ = await interceptor.retry(.unauthorized, for: second, retryCount: 0)
        let refreshes = await store.count()
        #expect(refreshes == 1)
    }

    @Test func refreshReturningNilShouldNotReportRetrySuccess() async {
        let interceptor = DefaultInterceptor(tokenProvider: { "old" }, refreshTokenProvider: { nil })
        var request = URLRequest(url: URL(string: "https://audit.invalid")!)
        request.setValue("Bearer old", forHTTPHeaderField: "Authorization")
        let decision = await interceptor.retry(.unauthorized, for: request, retryCount: 0)
        if case .retry = decision { Issue.record("Refresh returned nil but interceptor requests a retry") }
    }
    private actor PausedAdapter: RequestInterceptor {
        let gate: Gate
        init(gate: Gate) { self.gate = gate }
        func adapt(_ request: URLRequest) async throws -> URLRequest { await gate.pause(); return request }
    }

    @Test func cancellingParentStopsBackoff() async {
        StubProtocol.state.reset(failFirst: true)
        let gate = Gate()
        let client = NetworkClient(configuration: configuration(), interceptor: BackoffInterceptor(gate: gate))
        let task = Task { try await client.request(TestEndpoint(id: "parent")) }
        await gate.waitUntilEntered()
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request succeeded") }
        catch { #expect(error as? NetworkError == .cancelled) }
        #expect(StubProtocol.state.count("parent") == 1)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func cancelledBeforeStartNeverSends() async {
        StubProtocol.state.reset(failFirst: false)
        let client = NetworkClient(configuration: configuration())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.request(TestEndpoint(id: "pre-cancelled"))
        }
        do { _ = try await task.value; Issue.record("Cancelled request succeeded") }
        catch { #expect(error as? NetworkError == .cancelled) }
        #expect(StubProtocol.state.count("pre-cancelled") == 0)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func cancelDuringAdaptationDoesNotSend() async {
        StubProtocol.state.reset(failFirst: false)
        let gate = Gate()
        let client = NetworkClient(configuration: configuration(), interceptor: PausedAdapter(gate: gate))
        let id = UUID()
        let task = Task { try await client.request(TestEndpoint(id: "adapt"), taskId: id) }
        await gate.waitUntilEntered()
        await client.cancelRequest(taskId: id)
        await gate.open()
        do { _ = try await task.value; Issue.record("Cancelled request succeeded") }
        catch { #expect(error as? NetworkError == .cancelled) }
        #expect(StubProtocol.state.count("adapt") == 0)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func duplicateIDCannotReplaceAnActiveOperation() async throws {
        StubProtocol.state.reset(failFirst: false)
        let gate = Gate()
        let client = NetworkClient(configuration: configuration(), interceptor: PausedAdapter(gate: gate))
        let id = UUID()
        let first = Task { try await client.request(TestEndpoint(id: "duplicate"), taskId: id) }
        await gate.waitUntilEntered()
        do { _ = try await client.request(TestEndpoint(id: "duplicate"), taskId: id); Issue.record("Duplicate ID accepted") }
        catch { #expect(error as? NetworkError == .duplicateTaskID) }
        await gate.open()
        _ = try await first.value
        #expect(StubProtocol.state.count("duplicate") == 1)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func cancelAllIncludesBackoff() async {
        StubProtocol.state.reset(failFirst: true)
        let gate = Gate()
        let client = NetworkClient(configuration: configuration(), interceptor: BackoffInterceptor(gate: gate))
        let task = Task { try await client.request(TestEndpoint(id: "all")) }
        await gate.waitUntilEntered()
        await client.cancelAllRequests()
        do { _ = try await task.value; Issue.record("Cancelled request succeeded") }
        catch { #expect(error as? NetworkError == .cancelled) }
        #expect(StubProtocol.state.count("all") == 1)
        #expect(await client.activeRequestCount == 0)
    }

    private struct InvalidDelay: RequestInterceptor {
        let delay: Double
        func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision { .retryAfter(delay) }
    }

    @Test func invalidRetryDelayFailsWithoutTrap() async {
        for delay in [-1.0, .infinity, .nan] {
            StubProtocol.state.reset(failFirst: true)
            let client = NetworkClient(configuration: configuration(), interceptor: InvalidDelay(delay: delay))
            do { _ = try await client.request(TestEndpoint(id: "invalid-delay")); Issue.record("Unexpected success") }
            catch { #expect((error as? NetworkError)?.statusCode == 500) }
            #expect(StubProtocol.state.count("invalid-delay") == 1)
            #expect(await client.activeRequestCount == 0)
        }
    }

    @Test func missingRequiredTokenFailsBeforeTransport() async {
        struct Protected: Endpoint {
            typealias Response = ResultBody
            typealias Body = Never
            let baseURL = URL(string: "https://audit.invalid")!
            let path = "/same"
            let method = HTTPMethod.get
            let authorization = AuthorizationRequirement.required
        }
        for token: String? in [nil, "", "  "] {
            StubProtocol.state.reset(failFirst: false)
            let client = NetworkClient(configuration: configuration(), interceptor: DefaultInterceptor(tokenProvider: { token }))
            do { _ = try await client.request(Protected()); Issue.record("Missing token accepted") }
            catch { #expect((error as? NetworkError)?.isAuthenticationError == true) }
            #expect(StubProtocol.state.count("unspecified") == 0)
            #expect(await client.activeRequestCount == 0)
        }
    }

    @Test func anonymousPreparationDoesNotReadCredentials() async throws {
        let interceptor = DefaultInterceptor(tokenProvider: { throw NetworkError.unauthorized })
        var request = URLRequest(url: URL(string: "https://audit.invalid")!)
        request.setValue("Bearer should-be-removed", forHTTPHeaderField: "Authorization")
        let prepared = try await interceptor.prepare(request, authorization: .none)
        #expect(prepared.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func lateFailedRefreshIsNotRepeatedForAnOldPreparedRequest() async throws {
        let attempts = TokenStore()
        let interceptor = DefaultInterceptor(tokenProvider: { "old" }, refreshTokenProvider: {
            _ = await attempts.refresh()
            return nil
        })
        let request = URLRequest(url: URL(string: "https://audit.invalid")!)
        let first = try await interceptor.prepare(request)
        let late = try await interceptor.prepare(request)
        _ = await interceptor.retry(.unauthorized, for: first, retryCount: 0)
        _ = await interceptor.retry(.unauthorized, for: late, retryCount: 0)
        #expect(await attempts.count() == 1)
        let newRequest = try await interceptor.prepare(request)
        _ = await interceptor.retry(.unauthorized, for: newRequest, retryCount: 0)
        #expect(await attempts.count() == 2)
    }

    @Test func returnedTokenIsUsedEvenIfProviderHasNotPersistedItYet() async throws {
        let attempts = TokenStore()
        let interceptor = DefaultInterceptor(tokenProvider: { "old" }, refreshTokenProvider: { await attempts.refresh() })
        let base = URLRequest(url: URL(string: "https://audit.invalid")!)
        let first = try await interceptor.prepare(base)
        _ = await interceptor.retry(.unauthorized, for: first, retryCount: 0)
        let second = try await interceptor.prepare(base)
        #expect(second.request.value(forHTTPHeaderField: "Authorization") == "Bearer new-1")
        _ = await interceptor.retry(.unauthorized, for: second, retryCount: 0)
        let third = try await interceptor.prepare(base)
        #expect(third.request.value(forHTTPHeaderField: "Authorization") == "Bearer new-2")
        await interceptor.reset()
        let afterReset = try await interceptor.prepare(base)
        #expect(afterReset.request.value(forHTTPHeaderField: "Authorization") == "Bearer old")
    }

    private final class BlockingProtocol: URLProtocol, @unchecked Sendable {
        static let state = LockedState()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { _ = Self.state.next("started") }
        override func stopLoading() { _ = Self.state.next("stopped") }
    }

    @Test func cancellationStopsAnActiveURLSessionTask() async {
        BlockingProtocol.state.reset(failFirst: false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BlockingProtocol.self]
        let client = NetworkClient(configuration: config)
        let id = UUID()
        let task = Task { try await client.request(TestEndpoint(id: "blocked"), taskId: id) }
        let deadline = ContinuousClock.now + .seconds(2)
        while BlockingProtocol.state.count("started") == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(BlockingProtocol.state.count("started") == 1)
        await client.cancelRequest(taskId: id)
        do { _ = try await task.value; Issue.record("Transport was not cancelled") }
        catch { #expect(error as? NetworkError == .cancelled) }
        #expect(await client.activeRequestCount == 0)
        let stoppedDeadline = ContinuousClock.now + .seconds(2)
        while BlockingProtocol.state.count("stopped") == 0, ContinuousClock.now < stoppedDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(BlockingProtocol.state.count("stopped") == 1)
    }

    @Test func http401RefreshReplaysTheActualRequestWithTheNewToken() async throws {
        StubProtocol.state.reset(failFirst: true, status: 401)
        let interceptor = DefaultInterceptor(tokenProvider: { "old" }, refreshTokenProvider: { "fresh" })
        let client = NetworkClient(configuration: configuration(), interceptor: interceptor)
        let result = try await client.request(TestEndpoint(id: "refresh"))
        #expect(result.ok)
        #expect(StubProtocol.state.sentAuthorizations() == ["Bearer old", "Bearer fresh"])
        #expect(await client.activeRequestCount == 0)
    }

    @Test func refreshTransportFailureIsNotMisreportedAsUnauthorized() async {
        StubProtocol.state.reset(failFirst: true, status: 401)
        let interceptor = DefaultInterceptor(tokenProvider: { "old" }, refreshTokenProvider: { throw URLError(.timedOut) })
        let client = NetworkClient(configuration: configuration(), interceptor: interceptor)
        do { _ = try await client.request(TestEndpoint(id: "refresh-timeout")); Issue.record("Refresh should fail") }
        catch { #expect(error as? NetworkError == .timeout) }
        #expect(StubProtocol.state.count("refresh-timeout") == 1)
        #expect(await client.activeRequestCount == 0)
    }

    @Test func composingAdaptersPreservesRecoverySnapshot() async throws {
        let interceptor = DefaultInterceptor(tokenProvider: { "old" })
        let original = try await interceptor.prepare(URLRequest(url: URL(string: "https://audit.invalid")!))
        var request = original.request
        request.setValue("value", forHTTPHeaderField: "X-Custom")
        let composed = original.replacingRequest(request)
        #expect(composed.request.value(forHTTPHeaderField: "X-Custom") == "value")
        #expect(composed.refreshGeneration == original.refreshGeneration)
        #expect(composed.sessionEpoch == original.sessionEpoch)
    }

    @Test func resetPreventsReplayFromThePreviousSession() async throws {
        let interceptor = DefaultInterceptor(tokenProvider: { "old" }, refreshTokenProvider: { "new" }, retryPolicy: RetryPolicy())
        let previous = try await interceptor.prepare(URLRequest(url: URL(string: "https://audit.invalid")!))
        await interceptor.reset()
        for error in [NetworkError.unauthorized, .http(HTTPFailure(statusCode: 503))] {
            let decision = await interceptor.retry(error, for: previous, retryCount: 0)
            if case .fail(let failure) = decision { #expect(failure == .cancelled) }
            else { Issue.record("Old session request was not cancelled") }
        }
    }

}
