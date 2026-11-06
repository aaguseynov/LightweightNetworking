import Foundation
import Testing
@testable import LightweightNetworking

private actor Signal {
    var entered = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    var released: CheckedContinuation<Void, Never>?
    func wait() async { if !entered { await withCheckedContinuation { waiting.append($0) } } }
    func signal() { entered = true; let previous = waiting; waiting.removeAll(); previous.forEach { $0.resume() } }
    func pause() async {
        signal()
        await withCheckedContinuation { released = $0 }
    }
    func open() { released?.resume(); released = nil }
}
private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

@Suite
struct RefreshCoordinatorTests {
    private func waitForCount(_ count: Int, on coordinator: RefreshCoordinator) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while await coordinator.waiterCount != count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await coordinator.waiterCount == count)
    }

    @Test func failureIsSharedWithLateOldGenerationRequests() async {
        let coordinator = RefreshCoordinator()
        let counter = Counter()
        let version = await coordinator.generation
        for _ in 0..<2 {
            do {
                try await coordinator.run(since: version) {
                    await counter.increment()
                    throw NetworkError.unauthorized
                }
                Issue.record("Refresh should fail")
            } catch { #expect(error as? NetworkError == .unauthorized) }
        }
        #expect(await counter.value == 1)
        let next = await coordinator.generation
        try? await coordinator.run(since: next) { await counter.increment() }
        #expect(await counter.value == 2)
    }

    @Test func cancellingOneWaiterDoesNotCancelSharedRefresh() async throws {
        let coordinator = RefreshCoordinator()
        let gate = Signal()
        let counter = Counter()
        let version = await coordinator.generation
        let first = Task {
            try await coordinator.run(since: version) {
                await counter.increment()
                await gate.pause()
                try Task.checkCancellation()
            }
        }
        await gate.wait()
        let second = Task { try await coordinator.run(since: version) { await counter.increment() } }
        await waitForCount(2, on: coordinator)
        first.cancel()
        do { try await first.value; Issue.record("Cancelled waiter succeeded") }
        catch { #expect(error as? NetworkError == .cancelled) }
        await gate.open()
        try await second.value
        #expect(await counter.value == 1)
        #expect(await coordinator.waiterCount == 0)
    }

    @Test func lastWaiterCancellationSerializesTheNextRefresh() async throws {
        let coordinator = RefreshCoordinator()
        let cancellationGate = Signal()
        let started = Signal()
        let counter = Counter()
        let version = await coordinator.generation
        let first = Task {
            try await coordinator.run(since: version) {
                await counter.increment()
                await started.signal()
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    await cancellationGate.pause()
                    throw error
                }
            }
        }
        await started.wait()
        first.cancel()
        do { try await first.value; Issue.record("Cancelled waiter succeeded") } catch { }
        await cancellationGate.wait()
        let second = Task { try await coordinator.run(since: version) { await counter.increment() } }
        await waitForCount(1, on: coordinator)
        #expect(await counter.value == 1)
        await cancellationGate.open()
        try await second.value
        #expect(await counter.value == 2)
    }

    @Test func resetReleasesWaitersAndDoesNotReplayOldResults() async throws {
        let coordinator = RefreshCoordinator()
        let gate = Signal()
        let version = await coordinator.generation
        let first = Task { try await coordinator.run(since: version) { await gate.pause() } }
        await gate.wait()
        await coordinator.reset()
        do { try await first.value; Issue.record("Reset waiter succeeded") }
        catch { #expect(error as? NetworkError == .cancelled) }
        let newVersion = await coordinator.generation
        #expect(newVersion != version)
        try await coordinator.run(since: newVersion) { }
        await gate.open()
        #expect(await coordinator.waiterCount == 0)
    }
}
