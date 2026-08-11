import Foundation

@MainActor
final class ProjectPackageCoordinator {
    private var savesInProgress = 0
    private var activeMutations = 0
    private var nextMutationID = 0
    private var pendingMutations: [(id: Int, run: () -> Void, cancel: () -> Void)] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosing = false

    func saveStarted() { savesInProgress += 1 }

    func saveFinished(success: Bool) {
        guard savesInProgress > 0 else {
            assertionFailure("Unbalanced project save completion")
            return
        }
        savesInProgress -= 1
        guard savesInProgress == 0 else { return }
        let mutations = pendingMutations
        pendingMutations.removeAll()
        if !success {
            mutations.forEach { $0.cancel() }
        } else {
            mutations.forEach { $0.run() }
        }
        resumeIdleWaitersIfNeeded()
    }

    func beginMutation() throws {
        try Task.checkCancellation()
        guard !isClosing else { throw CancellationError() }
        activeMutations += 1
    }

    func endMutation() {
        guard activeMutations > 0 else {
            assertionFailure("Unbalanced project package mutation")
            return
        }
        activeMutations -= 1
        resumeIdleWaitersIfNeeded()
    }

    func performMutation<T: Sendable>(_ operation: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard savesInProgress > 0 else { return try operation() }

        let id = nextMutationID
        nextMutationID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingMutations.append((
                    id: id,
                    run: { continuation.resume(with: Result { try operation() }) },
                    cancel: { continuation.resume(throwing: CancellationError()) }
                ))
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelMutation(id: id) } }
    }

    func beginClosing() async {
        isClosing = true
        await waitUntilIdle()
    }

    func cancelClosing() { isClosing = false }

    func waitUntilIdle() async {
        guard savesInProgress > 0 || activeMutations > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func cancelMutation(id: Int) {
        guard let index = pendingMutations.firstIndex(where: { $0.id == id }) else { return }
        let mutation = pendingMutations.remove(at: index)
        mutation.cancel()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard savesInProgress == 0, activeMutations == 0 else { return }
        let waiting = idleWaiters
        idleWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
