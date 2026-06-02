import Foundation

/// Resolves asset IDs to file URLs using the media manifest.
final class MediaResolver: @unchecked Sendable {
    private let manifest: () -> MediaManifest
    private let projectURL: () -> URL?

    init(manifest: @escaping () -> MediaManifest, projectURL: @escaping () -> URL?) {
        self.manifest = manifest
        self.projectURL = projectURL
    }

    func resolveURL(for assetId: String) -> URL? {
        guard let url = expectedURL(for: assetId) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func expectedURL(for assetId: String) -> URL? {
        guard let entry = entry(for: assetId) else { return nil }
        switch entry.source {
        case .external(let absolutePath):
            return URL(fileURLWithPath: absolutePath)
        case .project(let relativePath):
            guard let base = projectURL() else { return nil }
            return base.appendingPathComponent(relativePath)
        }
    }

    func isMissing(for assetId: String) -> Bool {
        guard let url = expectedURL(for: assetId) else { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    func displayName(for assetId: String) -> String {
        entry(for: assetId)?.name ?? "Offline"
    }

    func entry(for assetId: String) -> MediaManifestEntry? {
        manifest().entries.first(where: { $0.id == assetId })
    }
}
