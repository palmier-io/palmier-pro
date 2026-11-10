import Foundation

/// A reusable motion-graphics block from the HyperFrames catalog (transitions,
/// overlays, captions, charts, maps, kinetic type, effects). Ids are registry
/// identifiers and are stable; never use display names as identity.
struct HyperframesBlock: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let tags: [String]
    let description: String
    /// Path relative to the catalog mirror root, e.g. "blocks/kinetic-title/block.json".
    let path: String
    /// Paths relative to the catalog mirror root for the block's asset files.
    let assets: [String]
    /// Optional preview image, relative to the mirror root.
    let preview: String?
    let minVersion: String?
    let defaultDurationFrames: Int?
    let requiredAdapters: [String]

    init(
        id: String,
        name: String,
        category: String,
        tags: [String] = [],
        description: String = "",
        path: String,
        assets: [String] = [],
        preview: String? = nil,
        minVersion: String? = nil,
        defaultDurationFrames: Int? = nil,
        requiredAdapters: [String] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.tags = tags
        self.description = description
        self.path = path
        self.assets = assets
        self.preview = preview
        self.minVersion = minVersion
        self.defaultDurationFrames = defaultDurationFrames
        self.requiredAdapters = requiredAdapters
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, tags, description, path, assets, preview
        case minVersion
        case defaultDurationFrames
        case requiredAdapters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(String.self, forKey: .category)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        path = try c.decode(String.self, forKey: .path)
        assets = try c.decodeIfPresent([String].self, forKey: .assets) ?? []
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        minVersion = try c.decodeIfPresent(String.self, forKey: .minVersion)
        defaultDurationFrames = try c.decodeIfPresent(Int.self, forKey: .defaultDurationFrames)
        requiredAdapters = try c.decodeIfPresent([String].self, forKey: .requiredAdapters) ?? []
    }

    /// Resolves `assetPath` (relative, or an absolute file URL path) against the mirror base.
    static func resolve(_ relative: String, base: URL) -> URL? {
        if relative.hasPrefix("file://") { return URL(string: relative) }
        let cleaned = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        return base.appendingPathComponent(cleaned)
    }
}

/// Reads the HyperFrames block catalog from a local mirror only — the hosted
/// registry was never wired into the build. Set COMPOSITOR_HYPERFRAMES_BASE to a
/// local clone (e.g. file:///path/hyperframes-catalog) to populate the catalog.
@Observable
@MainActor
final class HyperframesCatalog {
    static let shared = HyperframesCatalog()

    static var base: String {
        ProcessInfo.processInfo.environment["COMPOSITOR_HYPERFRAMES_BASE"] ?? ""
    }

    private(set) var blocks: [HyperframesBlock] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    private static var cacheURL: URL {
        DiskCache.rootDirectory.appendingPathComponent("hyperframes-catalog.json")
    }

    private init() { loadCache() }

    func block(id: String) -> HyperframesBlock? { blocks.first { $0.id == id } }

    /// Local, case-insensitive match over name/tags/description/category.
    func search(query: String, category: String? = nil) -> [HyperframesBlock] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return blocks.filter { block in
            if let category, !category.isEmpty, block.category.caseInsensitiveCompare(category) != .orderedSame {
                return false
            }
            guard !trimmed.isEmpty else { return true }
            if block.name.lowercased().contains(trimmed)
                || block.description.lowercased().contains(trimmed)
                || block.category.lowercased().contains(trimmed)
                || block.id.lowercased().contains(trimmed) {
                return true
            }
            return block.tags.contains { $0.lowercased().contains(trimmed) }
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let decoded = try? JSONDecoder().decode([HyperframesBlock].self, from: data)
        else { return }
        blocks = decoded
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !isLoading, !Self.base.isEmpty,
              let url = URL(string: "\(Self.base)/catalog.json"),
              url.isFileURL else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try Data(contentsOf: url)
            blocks = try JSONDecoder().decode([HyperframesBlock].self, from: data)
            lastError = nil
            try? FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: Self.cacheURL)
            Log.agent.notice("hyperframes catalog loaded \(self.blocks.count) blocks from \(Self.base)")
            return true
        } catch {
            lastError = error.localizedDescription
            Log.agent.error("hyperframes catalog refresh failed (\(Self.base)): \(error.localizedDescription)")
            return false
        }
    }

    /// Preview data for a block, read from the mirror only.
    static func previewData(for block: HyperframesBlock) -> Data? {
        guard !Self.base.isEmpty, let preview = block.preview,
              let url = URL(string: "\(Self.base)/\(preview)"), url.isFileURL else { return nil }
        return try? Data(contentsOf: url)
    }
}
