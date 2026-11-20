import Foundation

/// Defines a customizable parameter exposed by a HyperFrames block (e.g. title text, accent color).
struct HyperframesParameter: Codable, Sendable, Equatable, Identifiable {
    enum ParameterType: String, Codable, Sendable {
        case text
        case color
        case number
        case boolean
        case choice
    }

    var id: String
    var name: String
    var type: ParameterType
    var defaultValue: String
    var description: String?
    var choices: [String]?

    init(
        id: String,
        name: String,
        type: ParameterType,
        defaultValue: String,
        description: String? = nil,
        choices: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.description = description
        self.choices = choices
    }
}

/// Rich metadata and template spec for a HyperFrames motion block.
struct HyperframesBlockSpec: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var category: String
    var tags: [String]
    var description: String
    var path: String
    var assets: [String]
    var preview: String?
    var minVersion: String?
    var defaultDurationFrames: Int?
    var requiredAdapters: [String]
    var parameters: [HyperframesParameter]
    var htmlTemplate: String?

    init(
        id: String,
        name: String,
        category: String,
        tags: [String] = [],
        description: String = "",
        path: String = "",
        assets: [String] = [],
        preview: String? = nil,
        minVersion: String? = nil,
        defaultDurationFrames: Int? = 30,
        requiredAdapters: [String] = [],
        parameters: [HyperframesParameter] = [],
        htmlTemplate: String? = nil
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
        self.parameters = parameters
        self.htmlTemplate = htmlTemplate
    }

    /// Converts into a standard catalog block.
    func toBlock() -> HyperframesBlock {
        HyperframesBlock(
            id: id,
            name: name,
            category: category,
            tags: tags,
            description: description,
            path: path,
            assets: assets,
            preview: preview,
            minVersion: minVersion,
            defaultDurationFrames: defaultDurationFrames,
            requiredAdapters: requiredAdapters
        )
    }
}

/// Catalog package wrapper for reading, inspecting, and bundling HyperFrames blocks.
enum HyperframesCatalogWrapper {

    /// Builtin standard blocks if no external catalog is configured.
    static var standardBlocks: [HyperframesBlock] {
        [
            HyperframesBlock(
                id: "kinetic-title-reveal",
                name: "Kinetic Title Reveal",
                category: "Titles",
                tags: ["kinetic", "title", "intro", "modern"],
                description: "Bold animated title reveal with smooth ease-out typography.",
                path: "blocks/kinetic-title-reveal/block.json",
                defaultDurationFrames: 90
            ),
            HyperframesBlock(
                id: "split-feature-showcase",
                name: "Split Feature Showcase",
                category: "Showcase",
                tags: ["split", "product", "features"],
                description: "Dual-column presentation with staggered text and accent highlights.",
                path: "blocks/split-feature-showcase/block.json",
                defaultDurationFrames: 150
            ),
            HyperframesBlock(
                id: "stats-counter-banner",
                name: "Stats Counter Banner",
                category: "Data",
                tags: ["stats", "counter", "banner"],
                description: "Animated number ticker and stat cards.",
                path: "blocks/stats-counter-banner/block.json",
                defaultDurationFrames: 120
            ),
            HyperframesBlock(
                id: "badge-pop",
                name: "Badge Pop",
                category: "Badges",
                tags: ["badge", "pop", "overlay"],
                description: "Playful bouncy badge overlay for callouts and awards.",
                path: "blocks/badge-pop/block.json",
                defaultDurationFrames: 60
            )
        ]
    }

    /// Loads blocks from the runtime catalog and community repository.
    static func loadCatalog(includeCommunity: Bool = true) -> [HyperframesBlock] {
        var blocks = standardBlocks
        if includeCommunity {
            let community = HyperframesCommunityCatalog.shared.loadCommunityBlocks()
            for cb in community where !blocks.contains(where: { $0.id == cb.id }) {
                blocks.append(cb)
            }
        }
        return blocks
    }

    /// Inspects a block specification by ID, returning a spec if found.
    static func inspectBlock(id: String) -> HyperframesBlockSpec? {
        if let communitySpec = HyperframesCommunityCatalog.shared.loadCommunityBlockSpec(id: id) {
            return communitySpec
        }
        guard let block = loadCatalog().first(where: { $0.id == id }) else { return nil }
        return HyperframesBlockSpec(
            id: block.id,
            name: block.name,
            category: block.category,
            tags: block.tags,
            description: block.description,
            path: block.path,
            assets: block.assets,
            preview: block.preview,
            defaultDurationFrames: block.defaultDurationFrames,
            parameters: [
                HyperframesParameter(id: "title", name: "title", type: .text, defaultValue: block.name, description: "Main headline text"),
                HyperframesParameter(id: "subtitle", name: "subtitle", type: .text, defaultValue: block.description, description: "Secondary descriptive text")
            ]
        )
    }

    /// Loads blocks from a catalog root directory containing `catalog.json`.
    static func loadCatalog(from rootURL: URL) async throws -> [HyperframesBlock] {
        let catalogURL = rootURL.appendingPathComponent("catalog.json")
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: catalogURL)
        }.value
        return try JSONDecoder().decode([HyperframesBlock].self, from: data)
    }

    /// Inspects an individual block specification JSON file.
    static func inspectBlock(at blockURL: URL) async throws -> HyperframesBlockSpec {
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: blockURL)
        }.value
        return try JSONDecoder().decode(HyperframesBlockSpec.self, from: data)
    }

    /// Exports catalog metadata into a target directory.
    static func exportCatalog(_ blocks: [HyperframesBlock], to destinationURL: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(blocks)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let targetFile = destinationURL.appendingPathComponent("catalog.json")
            try data.write(to: targetFile, options: .atomic)
        }.value
    }

    /// Resolves asset file URLs for a given block against the mirror base URL.
    static func resolveAssets(for block: HyperframesBlock, mirrorRoot: URL) -> [URL] {
        block.assets.compactMap { HyperframesBlock.resolve($0, base: mirrorRoot) }
    }

    /// Verifies asset integrity, returning names of any missing or unreadable asset files.
    static func verifyBlockIntegrity(block: HyperframesBlock, mirrorRoot: URL) async -> [String] {
        await Task.detached(priority: .utility) {
            var missing: [String] = []
            for asset in block.assets {
                guard let url = HyperframesBlock.resolve(asset, base: mirrorRoot),
                      FileManager.default.fileExists(atPath: url.path) else {
                    missing.append(asset)
                    continue
                }
            }
            return missing
        }.value
    }

    /// Generates self-contained HTML for live WebView preview and rendering with injected parameters and design tokens.
    static func generateTemplateHTML(
        for spec: HyperframesBlockSpec,
        parameters: [String: String] = [:],
        designSpec: DesignSpec? = nil
    ) -> String {
        var resolvedParams: [String: String] = [:]
        for p in spec.parameters {
            resolvedParams[p.id] = parameters[p.id] ?? p.defaultValue
        }
        for (k, v) in parameters {
            resolvedParams[k] = v
        }

        let bg = designSpec?.palette.background?.hexString ?? "#000000"
        let text = designSpec?.palette.text?.hexString ?? "#ffffff"
        let primary = designSpec?.palette.primary?.hexString ?? "#007aff"
        let fontDisplay = designSpec?.typography.displayFont ?? "system-ui, -apple-system, sans-serif"
        let fontBody = designSpec?.typography.bodyFont ?? "system-ui, -apple-system, sans-serif"

        let titleText = resolvedParams["title"] ?? resolvedParams["text"] ?? spec.name
        let subtitleText = resolvedParams["subtitle"] ?? spec.description
        let accentColor = resolvedParams["color"] ?? resolvedParams["accentColor"] ?? primary

        if let customHTML = spec.htmlTemplate, !customHTML.isEmpty {
            var html = customHTML
            for (key, val) in resolvedParams {
                html = html.replacingOccurrences(of: "{{\(key)}}", with: val)
            }
            return html
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          :root {
            --bg: \(bg);
            --text: \(text);
            --primary: \(primary);
            --accent: \(accentColor);
            --font-display: "\(fontDisplay)", sans-serif;
            --font-body: "\(fontBody)", sans-serif;
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body {
            background-color: var(--bg);
            color: var(--text);
            font-family: var(--font-body);
            width: 100vw;
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: hidden;
          }
          .block-container {
            text-align: center;
            padding: 2rem;
            animation: fadeIn 0.8s cubic-bezier(0.16, 1, 0.3, 1) forwards;
          }
          h1 {
            font-family: var(--font-display);
            font-size: 3.5rem;
            letter-spacing: -0.02em;
            color: var(--accent);
            margin-bottom: 0.5rem;
          }
          p {
            font-size: 1.25rem;
            opacity: 0.8;
          }
          @keyframes fadeIn {
            from { opacity: 0; transform: translateY(16px) scale(0.96); }
            to { opacity: 1; transform: translateY(0) scale(1); }
          }
        </style>
        </head>
        <body>
          <div class="block-container">
            <h1>\(titleText)</h1>
            <p>\(subtitleText)</p>
          </div>
          <script>
            window.addEventListener("message", (event) => {
              if (event.data && typeof event.data.frame === "number") {
                document.body.style.opacity = Math.min(1, Math.max(0, event.data.frame / 15));
              }
            });
          </script>
        </body>
        </html>
        """
    }
}
