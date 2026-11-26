/// Bounded-concurrency primitive for async work. Used to gate fan-out tasks that
/// share a finite system resource (e.g. CoreMedia's audio decoders).
actor AsyncSemaphore {
    private var permits: Int
    private var nextWaiterID = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []

    init(value: Int) { self.permits = max(0, value) }

    func wait() async throws {
        if permits > 0 {
            permits -= 1
            return
        }

        try Task.checkCancellation()
        let id = nextWaiterID
        nextWaiterID += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume()
        } else {
            permits += 1
        }
    }

    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
