import Foundation

@MainActor
final class ProjectPackageCoordinator {
    struct CloseLease: Sendable, Equatable {
        fileprivate let id: UUID
        fileprivate let owner: UUID
    }

    struct IntentLease: Sendable {
        fileprivate let id: UUID
        fileprivate let owner: UUID
    }

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
        let intent: IntentLease?
        let continuation: CheckedContinuation<MutationLease, Error>
    }

    private struct CloseWaiter {
        let lease: CloseLease
        let continuation: CheckedContinuation<Void, Error>
    }

    @TaskLocal private static var currentIntent: IntentLease?

    private let identity = UUID()
    let io = ProjectPackageIO()
    private var intents: Set<UUID> = []
    private var admissionEpoch = UUID()
    private var mutations: Set<UUID> = []
    private var admissions: [Admission] = []
    private var saves: [@MainActor (SaveLease) -> Void] = []
    private var activeSave: SaveLease?
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeOwners: Set<UUID> = []
    private var closeWaiters: [UUID: CloseWaiter] = [:]
    var isClosing: Bool { isClosed || !closeOwners.isEmpty }
    private(set) var isClosed = false
    var onReopen: (@MainActor () -> Void)?

    var canFinishClosing: Bool { !isClosed && !closeOwners.isEmpty && isIdle }

    func admitIntent() throws -> IntentLease {
        try Task.checkCancellation()
        _ = try inheritedIntent()
        guard !isClosing, !isClosed else { throw CancellationError() }
        let lease = IntentLease(id: UUID(), owner: identity)
        intents.insert(lease.id)
        return lease
    }

    func validate(_ lease: IntentLease) throws {
        guard lease.owner == identity, intents.contains(lease.id), !isClosed else {
            throw CancellationError()
        }
    }

    func finishIntent(_ lease: IntentLease) {
        guard lease.owner == identity, intents.remove(lease.id) != nil else {
            assertionFailure("Unbalanced project intent completion")
            return
        }
        advance()
    }

    func withIntent<T>(
        operation: @MainActor (IntentLease) async throws -> T
    ) async throws -> T {
        if let inherited = try inheritedIntent() {
            try Task.checkCancellation()
            return try await operation(inherited)
        }
        return try await withIntent(admitIntent(), operation: operation)
    }

    func withIntent<T>(
        _ lease: IntentLease,
        operation: @MainActor (IntentLease) async throws -> T
    ) async throws -> T {
        let inherited = Self.currentIntent
        if let inherited, inherited.owner == lease.owner, inherited.id == lease.id {
            try validate(inherited)
            try Task.checkCancellation()
            return try await operation(lease)
        }
        return try await runIntent(lease) { lease in
            if let inherited { try self.validate(inherited) }
            try Task.checkCancellation()
            return try await operation(lease)
        }
    }

    private func runIntent<T>(
        _ lease: IntentLease,
        operation: @MainActor (IntentLease) async throws -> T
    ) async throws -> T {
        try validate(lease)
        defer { finishIntent(lease) }
        return try await Self.$currentIntent.withValue(lease) {
            try await operation(lease)
        }
    }

    @discardableResult
    func startIntent(
        operation: @escaping @MainActor (IntentLease) async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let reservation = Result { try admitIntent() }
        let task = Task { @MainActor in
            defer {
                backgroundTasks.removeValue(forKey: id)
                resumeIdleWaitersIfNeeded()
            }
            do {
                let lease = try reservation.get()
                try await runIntent(lease) { lease in
                    do {
                        try Task.checkCancellation()
                        try await operation(lease)
                    } catch {
                        onFailure(error)
                    }
                }
            } catch {
                onFailure(error)
            }
        }
        backgroundTasks[id] = task
        return task
    }

    func withMutation<T>(
        operation: @MainActor (MutationLease) async throws -> T
    ) async throws -> T {
        let lease = try await admitMutation()
        return try await runMutation(lease) { lease in
            try Task.checkCancellation()
            _ = try inheritedIntent()
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
        let admissionEpoch = self.admissionEpoch
        let reservation = Result { () throws -> (mutation: MutationLease?, intent: IntentLease?) in
            try Task.checkCancellation()
            let intent = try inheritedIntent()
            guard canAdmitMutation(intent: intent) else { throw CancellationError() }
            let mutation = saves.isEmpty && activeSave == nil && admissions.isEmpty ? grantMutation() : nil
            let ownedIntent: IntentLease?
            if intent != nil {
                let lease = IntentLease(id: UUID(), owner: identity)
                intents.insert(lease.id)
                ownedIntent = lease
            } else {
                ownedIntent = nil
            }
            return (mutation, ownedIntent)
        }
        let task = Task { @MainActor in
            defer {
                backgroundTasks.removeValue(forKey: id)
                resumeIdleWaitersIfNeeded()
            }
            do {
                let reserved = try reservation.get()
                if let intent = reserved.intent {
                    try await runIntent(intent) { _ in
                        try await self.runOwnedMutation(reserved.mutation, admissionEpoch: admissionEpoch,
                            operation: operation, onFailure: onFailure)
                    }
                } else {
                    try await runOwnedMutation(reserved.mutation, admissionEpoch: admissionEpoch,
                        operation: operation, onFailure: onFailure)
                }
            } catch {
                onFailure(error)
            }
        }
        backgroundTasks[id] = task
        return task
    }

    private func runOwnedMutation(
        _ reserved: MutationLease?,
        admissionEpoch: UUID,
        operation: @escaping @MainActor (MutationLease) async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async throws {
        let body: @MainActor (MutationLease) async throws -> Void = { lease in
            do {
                try Task.checkCancellation()
                _ = try self.inheritedIntent()
                try await operation(lease)
            } catch {
                onFailure(error)
            }
        }
        if let reserved {
            try await runMutation(reserved, operation: body)
        } else {
            if admissionEpoch != self.admissionEpoch {
                guard try inheritedIntent() != nil else { throw CancellationError() }
            }
            let lease = try await admitMutation()
            try await runMutation(lease, operation: body)
        }
    }

    @discardableResult
    func beginClosing() -> CloseLease? {
        guard !isClosed else { return nil }
        let lease = CloseLease(id: UUID(), owner: identity)
        let wasClosing = isClosing
        closeOwners.insert(lease.id)
        guard !wasClosing else { return lease }
        admissionEpoch = UUID()
        var retained: [Admission] = []
        for admission in admissions {
            if canAdmitMutation(intent: admission.intent) {
                retained.append(admission)
            } else {
                admission.continuation.resume(throwing: CancellationError())
            }
        }
        admissions = retained
        advance()
        return lease
    }

    func validate(_ lease: CloseLease) throws {
        guard lease.owner == identity, closeOwners.contains(lease.id), !isClosed else {
            throw CancellationError()
        }
    }

    func validateCloseContext() throws {
        // Closing cannot drain the intent that is executing the close itself.
        guard Self.currentIntent?.owner != identity else { throw CancellationError() }
    }

    func cancelClosing(_ lease: CloseLease) {
        guard !isClosed, lease.owner == identity, closeOwners.remove(lease.id) != nil else { return }
        let waiting = closeWaiters.filter { $0.value.lease == lease }
        for (id, waiter) in waiting {
            closeWaiters.removeValue(forKey: id)
            waiter.continuation.resume(throwing: CancellationError())
        }
        advance()
        if closeOwners.isEmpty { onReopen?() }
    }

    func finishClosing(_ lease: CloseLease) throws {
        try validate(lease)
        guard isIdle else { throw CancellationError() }
        isClosed = true
        closeOwners.removeAll()
        let waiting = closeWaiters.values
        closeWaiters.removeAll()
        for waiter in waiting { waiter.continuation.resume(throwing: CancellationError()) }
    }

    func waitUntilIdle(for lease: CloseLease) async throws {
        try validateCloseContext()
        try Task.checkCancellation()
        try validate(lease)
        if !isIdle {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { closeWaiters[id] = CloseWaiter(lease: lease, continuation: continuation) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.closeWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
                }
            }
        }
        try Task.checkCancellation()
        try validate(lease)
    }

    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private var isIdle: Bool {
        intents.isEmpty && mutations.isEmpty && admissions.isEmpty && saves.isEmpty && activeSave == nil && backgroundTasks.isEmpty
    }

    private func inheritedIntent() throws -> IntentLease? {
        guard let lease = Self.currentIntent else { return nil }
        try validate(lease)
        return lease
    }

    private func canAdmitMutation(intent: IntentLease?) -> Bool {
        guard !isClosed else { return false }
        if let intent {
            return intent.owner == identity && intents.contains(intent.id)
        }
        return !isClosing
    }

    private func admitMutation() async throws -> MutationLease {
        try Task.checkCancellation()
        let intent = try inheritedIntent()
        guard canAdmitMutation(intent: intent) else { throw CancellationError() }
        if saves.isEmpty, activeSave == nil, admissions.isEmpty {
            return grantMutation()
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    admissions.append(Admission(id: id, intent: intent, continuation: continuation))
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
        } else if !isClosed, mutations.isEmpty {
            while !admissions.isEmpty {
                let admission = admissions.removeFirst()
                guard canAdmitMutation(intent: admission.intent) else {
                    admission.continuation.resume(throwing: CancellationError())
                    continue
                }
                admission.continuation.resume(returning: grantMutation())
                break
            }
        }
        resumeIdleWaitersIfNeeded()
    }

    private func resumeIdleWaitersIfNeeded() {
        guard isIdle else { return }
        let waiting = idleWaiters
        idleWaiters.removeAll()
        waiting.forEach { $0.resume() }
        let closing = closeWaiters.values
        closeWaiters.removeAll()
        for waiter in closing { waiter.continuation.resume() }
    }
}
