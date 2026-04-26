/// Bounded-concurrency primitive for async work. Used to gate fan-out tasks that
/// share a finite system resource (e.g. CoreMedia's audio decoders).
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.permits = max(0, value) }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }
}
