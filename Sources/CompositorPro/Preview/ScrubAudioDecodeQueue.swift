import Foundation

final class ScrubAudioReaderExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "io.compositor.pro.scrub-reader", qos: .userInitiated)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}

@MainActor
final class ScrubAudioDecodeQueue {
    private typealias Operation = @MainActor @Sendable () async -> Void

    private var activeTask: Task<Void, Never>?
    private var pendingOperation: Operation?

    var hasWork: Bool { activeTask != nil }

    isolated deinit {
        activeTask?.cancel()
    }

    func submit(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        guard activeTask == nil else {
            pendingOperation = operation
            activeTask?.cancel()
            return
        }
        start(operation)
    }

    func cancel() {
        pendingOperation = nil
        // Retain the active decode until its reader has finished tearing down.
        activeTask?.cancel()
    }

    private func start(_ operation: @escaping Operation) {
        activeTask = Task { [weak self] in
            if !Task.isCancelled {
                await operation()
            }
            guard let self else { return }
            self.activeTask = nil
            if let pending = self.pendingOperation {
                self.pendingOperation = nil
                self.start(pending)
            }
        }
    }
}
