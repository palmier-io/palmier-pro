import Foundation

struct ProjectEntry: Codable, Identifiable, Sendable {
    let id: UUID
    var url: URL
    var createdDate: Date
    var lastOpenedDate: Date

    var name: String { url.deletingPathExtension().lastPathComponent }
    var isAccessible: Bool { FileManager.default.fileExists(atPath: url.path) }
}

@Observable
@MainActor
final class ProjectRegistry {
    static let shared = ProjectRegistry()

    private(set) var entries: [ProjectEntry] = []

    var sortedEntries: [ProjectEntry] {
        entries.sorted { $0.lastOpenedDate > $1.lastOpenedDate }
    }

    func id(for url: URL) -> UUID? {
        let resolved = url.standardizedFileURL
        return entries.first { $0.url.standardizedFileURL == resolved }?.id
    }

    private let fileURL: URL
    private let disk = ProjectRegistryDisk()
    private var isLoading = false
    private var pendingMutations: [(inout [ProjectEntry]) -> Void] = []

    private init() {
        fileURL = Project.storageDirectory.appendingPathComponent(Project.registryFilename)
        load()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        entries = Self.loadEntries(from: fileURL)
    }

    // MARK: - Mutations

    func register(_ url: URL) {
        let resolved = url.standardizedFileURL
        mutate { entries in
            if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == resolved }) {
                entries[index].lastOpenedDate = Date()
            } else {
                entries.append(ProjectEntry(id: UUID(), url: resolved, createdDate: Date(), lastOpenedDate: Date()))
            }
        }
    }

    func remove(_ url: URL) {
        let resolved = url.standardizedFileURL
        mutate { entries in
            entries.removeAll { $0.url.standardizedFileURL == resolved }
        }
    }

    func delete(_ url: URL) {
        Task { [weak self] in
            guard let self, await self.disk.trashIfPresent(url) else { return }
            self.remove(url)
        }
    }

    func updateURL(from oldURL: URL, to newURL: URL) {
        let resolvedOld = oldURL.standardizedFileURL
        let resolvedNew = newURL.standardizedFileURL
        mutate { entries in
            if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == resolvedOld }) {
                entries[index].url = resolvedNew
                entries[index].lastOpenedDate = Date()
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.disk.load(from: self.fileURL)
            self.finishLoading(loaded)
        }
    }

    private func save() {
        Self.saveEntries(entries, to: fileURL)
    }

    private func mutate(_ apply: @escaping (inout [ProjectEntry]) -> Void) {
        guard !isLoading else {
            pendingMutations.append(apply)
            return
        }
        apply(&entries)
        save()
    }

    private func finishLoading(_ loaded: [ProjectEntry]) {
        entries = loaded
        isLoading = false
        guard !pendingMutations.isEmpty else { return }

        let mutations = pendingMutations
        pendingMutations.removeAll()
        for mutation in mutations {
            mutation(&entries)
        }
        save()
    }

    fileprivate nonisolated static func loadEntries(from fileURL: URL) -> [ProjectEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ProjectEntry].self, from: data) else { return [] }
        return decoded
    }

    fileprivate nonisolated static func saveEntries(_ entries: [ProjectEntry], to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private actor ProjectRegistryDisk {
    func load(from fileURL: URL) -> [ProjectEntry] {
        Project.ensureStorageDirectory()
        return ProjectRegistry.loadEntries(from: fileURL)
    }

    func trashIfPresent(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }
}
