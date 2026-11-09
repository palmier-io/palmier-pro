import Foundation

/// One entry in a skill catalog. `sha` is a content hash of the SKILL.md
/// and is the version anchor: a changed sha means an update is available.
struct SkillCatalogEntry: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let sha: String
    let path: String
}

/// Reads skills from a local catalog file only. The hosted community catalog
/// was removed in the backend teardown (R1); use COMPOSITOR_SKILLS_BASE to
/// point at a local file:// mirror.
@Observable
@MainActor
final class SkillCatalog {
    static let shared = SkillCatalog()

    /// Catalog source. Override with the COMPOSITOR_SKILLS_BASE env var to test against a
    /// local clone, e.g. file:///path/compositor-skills.
    static var base: String {
        ProcessInfo.processInfo.environment["COMPOSITOR_SKILLS_BASE"]
            ?? ""
    }

    private(set) var entries: [SkillCatalogEntry] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    private static var cacheURL: URL {
        DiskCache.rootDirectory.appendingPathComponent("skills-catalog.json")
    }

    private init() { loadCache() }

    func entry(id: String) -> SkillCatalogEntry? { entries.first { $0.id == id } }

    static func bodyURL(path: String) -> URL? { URL(string: "\(base)/\(path)") }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let decoded = try? JSONDecoder().decode([SkillCatalogEntry].self, from: data)
        else { return }
        entries = decoded
    }

    @discardableResult
    func refresh() async -> Bool {
        // Local-only: read the configured file:// mirror, never the network.
        guard !isLoading, !Self.base.isEmpty, let url = URL(string: "\(Self.base)/catalog.json"),
              url.isFileURL else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await Self.fetch(url)
            entries = try JSONDecoder().decode([SkillCatalogEntry].self, from: data)
            lastError = nil
            try? FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: Self.cacheURL)
            Log.agent.notice("skill catalog loaded \(self.entries.count) entries from \(Self.base)")
            return true
        } catch {
            lastError = error.localizedDescription
            Log.agent.error("skill catalog refresh failed (\(Self.base)): \(error.localizedDescription)")
            return false
        }
    }

    /// Reads a catalog/body file. Network URLs are refused.
    static func fetch(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw URLError(.badServerResponse) }
        return try Data(contentsOf: url)
    }
}
