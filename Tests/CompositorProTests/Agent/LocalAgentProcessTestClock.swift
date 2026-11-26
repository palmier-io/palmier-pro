import Foundation
import Synchronization

final class LocalAgentProcessTestClock: Clock, Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = ContinuousClock.now
        var waiters: [UUID: Waiter] = [:]
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())
    private let scheduledContinuation: AsyncStream<Instant>.Continuation
    let scheduled: AsyncStream<Instant>
    let minimumResolution: Duration = .nanoseconds(1)

    init() {
        (scheduled, scheduledContinuation) = AsyncStream.makeStream()
    }

    var now: Instant { state.withLock { $0.now } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        defer { _ = state.withLock { $0.cancelled.remove(id) } }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = state.withLock {
                    if $0.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if $0.now >= deadline { return .success(()) }
                    $0.waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                } else {
                    scheduledContinuation.yield(deadline)
                }
            }
        } onCancel: {
            let waiter = self.state.withLock {
                let waiter = $0.waiters.removeValue(forKey: id)
                if waiter == nil { $0.cancelled.insert(id) }
                return waiter
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(to instant: Instant) {
        let ready = state.withLock {
            precondition(instant >= $0.now)
            $0.now = instant
            let ready = $0.waiters.filter { $0.value.deadline <= instant }
            for id in ready.keys { $0.waiters[id] = nil }
            return Array(ready.values)
        }
        for waiter in ready { waiter.continuation.resume() }
    }

    func finishObservations() { scheduledContinuation.finish() }
}
