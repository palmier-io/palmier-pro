import Foundation

@MainActor
final class ProjectPackageCoordinator {
    struct MutationLease: Sendable {
        fileprivate let id: UUID
        fileprivate let owner: UUID
    }

    struct SaveLease: Sendable {
        fileprivate let id: UUID
        fileprivate let owner: UUID
    }

    private struct Admission {
        let id: UUID
        let continuation: CheckedContinuation<MutationLease, Error>
    }

    private let identity = UUID()
    let io = ProjectPackageIO()
    private var mutations: Set<UUID> = []
    private var admissions: [Admission] = []
    private var saves: [@MainActor (SaveLease) -> Void] = []
    private var activeSave: SaveLease?
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isClosing = false
    private(set) var isClosed = false
    var onReopen: (@MainActor () -> Void)?

    var canFinishClosing: Bool { isClosing && isIdle }

    func withMutation<T>(
        operation: @MainActor (MutationLease) async throws -> T
    ) async throws -> T {
        let lease = try await admitMutation()
        return try await runMutation(lease) { lease in
            try Task.checkCancellation()
            return try await operation(lease)
        }
    }

    private func runMutation<T>(
        _ lease: MutationLease,
        operation: @MainActor (MutationLease) async throws -> T
    ) async throws -> T {
        defer {
            mutations.remove(lease.id)
            advance()
        }
        return try await operation(lease)
    }

    func validate(_ lease: MutationLease) throws {
        guard lease.owner == identity, mutations.contains(lease.id), !isClosed else {
            throw CancellationError()
        }
    }

    func enqueueSave(start: @escaping @MainActor (SaveLease) -> Void) {
        saves.append(start)
        advance()
    }

    func finishSave(_ lease: SaveLease, completion: @MainActor () -> Void) {
        guard activeSave?.id == lease.id, lease.owner == identity else {
            assertionFailure("Unbalanced project save completion")
            return
        }
        completion()
        activeSave = nil
        advance()
    }

    @discardableResult
    func startMutation(
        operation: @escaping @MainActor (MutationLease) async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let reserved = !isClosing && !isClosed && saves.isEmpty && activeSave == nil && admissions.isEmpty ? grantMutation() : nil
        let task = Task { @MainActor in
            defer {
                backgroundTasks.removeValue(forKey: id)
                resumeIdleWaitersIfNeeded()
            }
            do {
                let body: @MainActor (MutationLease) async throws -> Void = { lease in
                    do {
                        try Task.checkCancellation()
                        try await operation(lease)
                    } catch {
                        onFailure(error)
                    }
                }
                if let reserved { try await runMutation(reserved, operation: body) }
                else {
                    let lease = try await admitMutation()
                    try await runMutation(lease, operation: body)
                }
            } catch {
                onFailure(error)
            }
        }
        backgroundTasks[id] = task
        return task
    }

    func beginClosing() {
        isClosing = true
        let waiting = admissions
        admissions.removeAll()
        waiting.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    func cancelClosing() {
        guard !isClosed else { return }
        isClosing = false
        advance()
        onReopen?()
    }

    func finishClosing() {
        guard canFinishClosing else { return }
        isClosing = true
        isClosed = true
    }

    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private var isIdle: Bool {
        mutations.isEmpty && saves.isEmpty && activeSave == nil && backgroundTasks.isEmpty
    }

    private func admitMutation() async throws -> MutationLease {
        try Task.checkCancellation()
        guard !isClosing, !isClosed else { throw CancellationError() }
        if saves.isEmpty, activeSave == nil, admissions.isEmpty {
            return grantMutation()
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    admissions.append(Admission(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAdmission(id) }
        }
    }

    private func grantMutation() -> MutationLease {
        let lease = MutationLease(id: UUID(), owner: identity)
        mutations.insert(lease.id)
        return lease
    }

    private func cancelAdmission(_ id: UUID) {
        guard let index = admissions.firstIndex(where: { $0.id == id }) else { return }
        admissions.remove(at: index).continuation.resume(throwing: CancellationError())
        advance()
    }

    private func advance() {
        guard activeSave == nil else { return }
        if !saves.isEmpty {
            guard mutations.isEmpty else { return }
            let start = saves.removeFirst()
            let lease = SaveLease(id: UUID(), owner: identity)
            activeSave = lease
            start(lease)
        } else if !isClosing, !isClosed {
            if mutations.isEmpty, !admissions.isEmpty {
                admissions.removeFirst().continuation.resume(returning: grantMutation())
            }
        }
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isIdle else { return }
        let waiting = idleWaiters
        idleWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
