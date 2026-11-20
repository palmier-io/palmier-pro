import Foundation

/// Validation issue reported when validating a community HyperFrames template.
struct HyperframesValidationIssue: Codable, Sendable, Equatable {
    enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    let severity: Severity
    let field: String
    let message: String
}

/// Manages community-contributed and locally installed HyperFrames templates.
/// Stored in `Application Support/Compositor Pro/HyperFrames/Community/`.
final class HyperframesCommunityCatalog: Sendable {
    static let shared = HyperframesCommunityCatalog()

    /// Base storage directory for community templates.
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        if let dir = rootDirectory {
            self.rootDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDirectory = appSupport.appendingPathComponent("Compositor Pro/HyperFrames/Community", isDirectory: true)
        }
    }

    /// Discovers all community blocks on disk.
    func loadCommunityBlocks() -> [HyperframesBlock] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var blocks: [HyperframesBlock] = []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let specURL = entry.appendingPathComponent("template.json")
            guard let data = try? Data(contentsOf: specURL),
                  let spec = try? JSONDecoder().decode(HyperframesBlockSpec.self, from: data) else {
                continue
            }
            blocks.append(spec.toBlock())
        }
        return blocks
    }

    /// Loads the full specification for a community block.
    func loadCommunityBlockSpec(id: String) -> HyperframesBlockSpec? {
        let blockDir = rootDirectory.appendingPathComponent(id, isDirectory: true)
        let specURL = blockDir.appendingPathComponent("template.json")
        guard let data = try? Data(contentsOf: specURL),
              var spec = try? JSONDecoder().decode(HyperframesBlockSpec.self, from: data) else {
            return nil
        }
        let htmlURL = blockDir.appendingPathComponent("index.html")
        if let html = try? String(contentsOf: htmlURL, encoding: .utf8) {
            spec.htmlTemplate = html
        }
        return spec
    }

    /// Validates a template package before installation.
    func validateTemplate(at url: URL) async throws -> [HyperframesValidationIssue] {
        var issues: [HyperframesValidationIssue] = []

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return [HyperframesValidationIssue(severity: .error, field: "path", message: "Template path does not exist")]
        }

        let specURL = isDir.boolValue ? url.appendingPathComponent("template.json") : url
        guard let data = try? Data(contentsOf: specURL) else {
            return [HyperframesValidationIssue(severity: .error, field: "template.json", message: "Missing or unreadable template.json")]
        }

        do {
            let spec = try JSONDecoder().decode(HyperframesBlockSpec.self, from: data)
            if spec.id.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(HyperframesValidationIssue(severity: .error, field: "id", message: "Block id cannot be empty"))
            }
            if spec.name.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(HyperframesValidationIssue(severity: .error, field: "name", message: "Block name cannot be empty"))
            }
            if spec.category.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(HyperframesValidationIssue(severity: .warning, field: "category", message: "Missing category; will default to Community"))
            }
            if spec.htmlTemplate == nil && isDir.boolValue {
                let htmlURL = url.appendingPathComponent("index.html")
                if !FileManager.default.fileExists(atPath: htmlURL.path) {
                    issues.append(HyperframesValidationIssue(severity: .error, field: "index.html", message: "No htmlTemplate defined and index.html not found"))
                }
            }
        } catch {
            issues.append(HyperframesValidationIssue(severity: .error, field: "template.json", message: "JSON decode error: \(error.localizedDescription)"))
        }

        return issues
    }

    /// Installs a new community template package into the catalog.
    @discardableResult
    func installTemplate(
        spec: HyperframesBlockSpec,
        html: String,
        assets: [URL] = []
    ) async throws -> HyperframesBlock {
        let blockDir = rootDirectory.appendingPathComponent(spec.id, isDirectory: true)
        try FileManager.default.createDirectory(at: blockDir, withIntermediateDirectories: true)

        let specURL = blockDir.appendingPathComponent("template.json")
        let htmlURL = blockDir.appendingPathComponent("index.html")

        var storedSpec = spec
        storedSpec.htmlTemplate = nil // keep in index.html
        let data = try JSONEncoder().encode(storedSpec)
        try data.write(to: specURL, options: .atomic)
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        if !assets.isEmpty {
            let assetDir = blockDir.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assetDir, withIntermediateDirectories: true)
            for asset in assets {
                let dest = assetDir.appendingPathComponent(asset.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: asset, to: dest)
            }
        }

        return spec.toBlock()
    }

    /// Uninstalls a community template.
    func uninstallTemplate(id: String) async throws {
        let blockDir = rootDirectory.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: blockDir.path) {
            try FileManager.default.removeItem(at: blockDir)
        }
    }
}

