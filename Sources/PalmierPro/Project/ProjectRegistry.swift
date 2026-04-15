import Foundation

struct ProjectEntry: Codable, Identifiable {
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

    private let fileURL: URL

    private init() {
        fileURL = Project.storageDirectory.appendingPathComponent(Project.registryFilename)
        load()
    }

    // MARK: - Mutations

    func register(_ url: URL) {
        let resolved = url.standardizedFileURL
        if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == resolved }) {
            entries[index].lastOpenedDate = Date()
        } else {
            entries.append(ProjectEntry(id: UUID(), url: resolved, createdDate: Date(), lastOpenedDate: Date()))
        }
        save()
    }

    func remove(_ url: URL) {
        let resolved = url.standardizedFileURL
        entries.removeAll { $0.url.standardizedFileURL == resolved }
        save()
    }

    /// Moves the project file to Trash and removes it from the registry.
    func delete(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        remove(url)
    }

    func updateURL(from oldURL: URL, to newURL: URL) {
        let resolvedOld = oldURL.standardizedFileURL
        if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == resolvedOld }) {
            entries[index].url = newURL.standardizedFileURL
            entries[index].lastOpenedDate = Date()
            save()
        }
    }

    // MARK: - Migration

    func migrateDefaultDirectoryIfNeeded() {
        let key = "ProjectRegistryMigrated"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: Project.storageDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in contents where fileURL.pathExtension == Project.fileExtension {
            let resolved = fileURL.standardizedFileURL
            guard !entries.contains(where: { $0.url.standardizedFileURL == resolved }) else { continue }
            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            entries.append(ProjectEntry(id: UUID(), url: resolved, createdDate: modDate, lastOpenedDate: modDate))
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ProjectEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
