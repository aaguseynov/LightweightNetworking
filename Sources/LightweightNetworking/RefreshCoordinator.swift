import Foundation

/// Recovery coordination knows nothing about token formats or HTTP transport.
actor RefreshCoordinator {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let operation: @Sendable () async throws -> Void
    }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
        var cancelling = false
    }

    private var flight: Flight?
    private(set) var generation = UUID()
    private var completed: Result<Void, Error>?
    var waiterCount: Int { flight?.waiters.count ?? 0 }

    func run(since expected: UUID, operation: @escaping @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if expected != generation {
                    continuation.resume(with: completed ?? .success(()))
                } else {
                    let waiter = Waiter(continuation: continuation, operation: operation)
                    if flight == nil { start(waiters: [id: waiter]) }
                    else { flight?.waiters[id] = waiter }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func reset() {
        let old = flight
        flight = nil
        generation = UUID()
        completed = .failure(NetworkError.cancelled)
        old?.task.cancel()
        old?.waiters.values.forEach { $0.continuation.resume(throwing: NetworkError.cancelled) }
    }

    private func start(waiters: [UUID: Waiter]) {
        guard let work = waiters.values.first?.operation else { return }
        let id = UUID()
        let task = Task {
            let result: Result<Void, Error>
            do { try await work(); result = .success(()) }
            catch { result = .failure(error) }
            complete(id, result: result)
        }
        flight = Flight(id: id, task: task, waiters: waiters)
    }

    private func cancel(_ id: UUID) {
        guard let waiter = flight?.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: NetworkError.cancelled)
        if flight?.waiters.isEmpty == true {
            flight?.cancelling = true
            flight?.task.cancel()
        }
    }

    private func complete(_ id: UUID, result: Result<Void, Error>) {
        guard let previous = flight, previous.id == id else { return }
        flight = nil
        if previous.cancelling {
            // New callers wait for the cancelled refresh to finish before another one starts.
            start(waiters: previous.waiters)
            return
        }
        generation = UUID()
        completed = result
        previous.waiters.values.forEach { $0.continuation.resume(with: result) }
    }
}
