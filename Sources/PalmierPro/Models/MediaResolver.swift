import Foundation

/// Resolves asset IDs to file URLs using the media manifest.
final class MediaResolver: @unchecked Sendable {
    private let manifest: () -> MediaManifest
    private let projectURL: () -> URL?
    private var cachedEntries: [String: MediaManifestEntry] = [:]

    init(manifest: @escaping () -> MediaManifest, projectURL: @escaping () -> URL?) {
        self.manifest = manifest
        self.projectURL = projectURL
    }

    func resolveURL(for assetId: String) -> URL? {
        guard let entry = lookupEntry(assetId) else { return nil }
        let url: URL
        switch entry.source {
        case .external(let absolutePath):
            url = URL(fileURLWithPath: absolutePath)
        case .project(let relativePath):
            guard let base = projectURL() else { return nil }
            url = base.appendingPathComponent(relativePath)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func displayName(for assetId: String) -> String {
        lookupEntry(assetId)?.name ?? "Offline"
    }

    private func lookupEntry(_ assetId: String) -> MediaManifestEntry? {
        let m = manifest()
        if m.entries.count != cachedEntries.count {
            cachedEntries = Dictionary(uniqueKeysWithValues: m.entries.map { ($0.id, $0) })
        }
        return cachedEntries[assetId]
    }
}
