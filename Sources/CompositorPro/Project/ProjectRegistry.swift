import Foundation

struct ProjectEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var url: URL
    var createdDate: Date
    var lastOpenedDate: Date

    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct ProjectAccessibility: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let id: UUID
        let url: URL

        init(_ entry: ProjectEntry) {
            id = entry.id
            url = entry.url
        }
    }

    enum State: Sendable {
        case available
        case missing
        case unavailable
    }

    let key: Key
    let state: State

    var isAccessible: Bool { state == .available }

    private static let gate = AsyncSemaphore(value: 1)

    @concurrent
    static func check(
        _ keys: [Key], read: @Sendable (URL) throws -> Bool = readAccessibility
    ) async throws -> [Self] {
        try Task.checkCancellation()
        guard !keys.isEmpty else { return [] }
        try await gate.wait()
        let results: [Self]
        do {
            var states: [URL: State] = [:]
            var checked: [Self] = []
            checked.reserveCapacity(keys.count)
            for key in keys {
                try Task.checkCancellation()
                let state: State
                if let existing = states[key.url] {
                    state = existing
                } else if !key.url.isFileURL {
                    state = .unavailable
                    states[key.url] = state
                } else {
                    do { state = try read(key.url) ? .available : .unavailable }
                    catch let error as CancellationError {
                        throw error
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                        state = .missing
                    } catch {
                        state = .unavailable
                    }
                    states[key.url] = state
                }
                checked.append(Self(key: key, state: state))
            }
            results = checked
        } catch {
            await gate.signal()
            throw error
        }
        await gate.signal()
        try Task.checkCancellation()
        return results
    }

    private static func readAccessibility(_ url: URL) throws -> Bool {
        let freshURL = URL(fileURLWithPath: url.path)
        return try freshURL.resourceValues(forKeys: [.isReadableKey]).isReadable == true
    }
}

struct ProjectDeletionResult: Sendable {
    let deletedIDs: Set<UUID>
    let failedNames: [String]
}

struct ProjectRegistryPersistenceError: Error, Equatable, Sendable {
    enum Code: String, Sendable {
        case loadFailed = "registry_load_failed"
        case writeFailed = "registry_write_failed"
    }

    let code: Code
    let underlyingDomain: String
    let underlyingCode: Int

    fileprivate init(code: Code, underlyingError: Error) {
        let error = underlyingError as NSError
        self.code = code
        underlyingDomain = error.domain
        underlyingCode = error.code
    }
}

@Observable
@MainActor
final class ProjectRegistry {
    static let shared = ProjectRegistry()

    private(set) var entries: [ProjectEntry] = []
    private(set) var isLoading = true
    private(set) var persistenceError: ProjectRegistryPersistenceError?

    var sortedEntries: [ProjectEntry] {
        entries.sorted { $0.lastOpenedDate > $1.lastOpenedDate }
    }

    func id(for url: URL) -> UUID? {
        let resolved = url.standardizedFileURL
        return entries.first { $0.url.standardizedFileURL.path == resolved.path }?.id
    }

    private let fileURL: URL
    private let disk = ProjectRegistryDisk()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var persistedEntries: [ProjectEntry] = []
    @ObservationIgnored private var loadError: ProjectRegistryPersistenceError?
    @ObservationIgnored private var pendingMutations: [(inout [ProjectEntry]) -> Void] = []

    private convenience init() {
        self.init(fileURL: Project.storageDirectory.appendingPathComponent(Project.registryFilename))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        loadTask = Task {
            do {
                let loaded = try await self.disk.load(from: self.fileURL)
                self.finishLoading(loaded)
            } catch {
                let failure = ProjectRegistryPersistenceError(code: .loadFailed, underlyingError: error)
                self.loadError = failure
                self.persistenceError = failure
                self.pendingMutations.removeAll()
                self.isLoading = false
            }
            self.loadTask = nil
        }
    }

    // MARK: - Mutations

    func register(_ url: URL) {
        let resolved = url.standardizedFileURL
        let date = Date()
        mutate { entries in
            if let index = entries.firstIndex(where: { $0.url.standardizedFileURL.path == resolved.path }) {
                entries[index].lastOpenedDate = date
            } else {
                entries.append(ProjectEntry(id: UUID(), url: resolved, createdDate: date, lastOpenedDate: date))
            }
        }
    }

    func remove(_ url: URL) {
        let resolved = url.standardizedFileURL
        mutate { entries in
            entries.removeAll { $0.url.standardizedFileURL.path == resolved.path }
        }
    }

    func delete(_ entries: [ProjectEntry]) async -> ProjectDeletionResult {
        do { try await waitUntilLoaded() }
        catch {
            return ProjectDeletionResult(deletedIDs: [], failedNames: entries.map(\.name))
        }
        let results = await disk.trash(entries)
        let deletedIDs = Set(results.compactMap { $0.deleted ? $0.id : nil })
        if !deletedIDs.isEmpty {
            mutate { current in current.removeAll { deletedIDs.contains($0.id) } }
        }
        return ProjectDeletionResult(
            deletedIDs: deletedIDs,
            failedNames: results.compactMap { $0.deleted ? nil : $0.name }
        )
    }

    func updateURL(from oldURL: URL, to newURL: URL) {
        let resolvedOld = oldURL.standardizedFileURL
        let resolvedNew = newURL.standardizedFileURL
        guard resolvedOld.path != resolvedNew.path else { return }
        let date = Date()
        mutate { entries in
            if let index = entries.firstIndex(where: { $0.url.standardizedFileURL.path == resolvedOld.path }) {
                entries[index].url = resolvedNew
                entries[index].lastOpenedDate = date
            }
        }
    }

    // MARK: - Persistence

    func waitUntilLoaded() async throws {
        try Task.checkCancellation()
        await loadTask?.value
        try Task.checkCancellation()
        if let loadError { throw loadError }
    }

    func flush() async throws {
        try await waitUntilLoaded()
        persistIfNeeded()
        while let task = persistenceTask {
            await task.value
            try Task.checkCancellation()
            if let persistenceError { throw persistenceError }
            persistIfNeeded()
        }
        if let persistenceError { throw persistenceError }
    }

    private func mutate(_ apply: @escaping (inout [ProjectEntry]) -> Void) {
        guard loadError == nil else { return }
        guard !isLoading else {
            pendingMutations.append(apply)
            return
        }
        var updated = entries
        apply(&updated)
        guard updated != entries else { return }
        entries = updated
        persistIfNeeded()
    }

    private func finishLoading(_ loaded: [ProjectEntry]) {
        entries = loaded
        persistedEntries = loaded
        isLoading = false
        guard !pendingMutations.isEmpty else { return }

        let mutations = pendingMutations
        pendingMutations.removeAll()
        var updated = loaded
        for mutation in mutations { mutation(&updated) }
        if updated != entries { entries = updated }
        persistIfNeeded()
    }

    private func persistIfNeeded() {
        guard !isLoading, loadError == nil, persistenceTask == nil,
              entries != persistedEntries || persistenceError != nil else { return }
        persistenceTask = Task {
            while self.entries != self.persistedEntries || self.persistenceError != nil {
                let snapshot = self.entries
                do {
                    try await self.disk.save(snapshot, to: self.fileURL)
                    self.persistedEntries = snapshot
                    self.persistenceError = nil
                } catch {
                    self.persistenceError = ProjectRegistryPersistenceError(code: .writeFailed, underlyingError: error)
                    break
                }
            }
            self.persistenceTask = nil
        }
    }
}

private final class ProjectRegistryDisk: Sendable {
    private let queue = DispatchQueue(label: "compositor.project-registry-io", qos: .utility)

    struct TrashResult: Sendable {
        let id: UUID
        let name: String
        let deleted: Bool
    }

    private func perform<T: Sendable>(
        phase: String, _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    let failure = error as NSError
                    Log.project.error("registry \(phase) failed domain=\(failure.domain) code=\(failure.code)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func load(from fileURL: URL) async throws -> [ProjectEntry] {
        try await perform(phase: "load") {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return []
            }
            return try JSONDecoder().decode([ProjectEntry].self, from: data)
        }
    }

    func save(_ entries: [ProjectEntry], to fileURL: URL) async throws {
        try await perform(phase: "write") {
            let data = try JSONEncoder().encode(entries)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    func trash(_ entries: [ProjectEntry]) async -> [TrashResult] {
        await withCheckedContinuation { continuation in
            queue.async {
                let results = entries.map { entry in
                    let deleted: Bool
                    if !FileManager.default.fileExists(atPath: entry.url.path) {
                        deleted = true
                    } else {
                        do {
                            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
                            deleted = true
                        } catch {
                            let failure = error as NSError
                            Log.project.error("registry trash failed id=\(entry.id) domain=\(failure.domain) code=\(failure.code)")
                            deleted = false
                        }
                    }
                    return TrashResult(id: entry.id, name: entry.name, deleted: deleted)
                }
                continuation.resume(returning: results)
            }
        }
    }
}
