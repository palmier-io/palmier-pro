import Foundation

// Reconnect offline media by repointing assets at a relocated source file or folder.
extension EditorViewModel {

    /// Repoint a single asset at a new source file, re-validate, and rebuild.
    func relinkAsset(id: String, to newURL: URL) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        if let newType = ClipType(fileExtension: newURL.pathExtension.lowercased()), newType != asset.type {
            mediaPanelToast = "Can't relink — \"\(newURL.lastPathComponent)\" is \(newType.trackLabel.lowercased()), not \(asset.type.trackLabel.lowercased())."
            return
        }
        applyRelink(id: id, to: newURL)
        notifyTimelineChanged()
    }

    /// Match every offline asset to a same-named file under `folder` (recursive) and relink it.
    @discardableResult
    func relinkOfflineAssets(fromFolder folder: URL) -> (relinked: Int, total: Int) {
        let offline = mediaAssets.filter { isMediaOffline($0.id) }
        guard !offline.isEmpty else { return (0, 0) }
        let index = fileIndex(in: folder)
        var relinked = 0
        for asset in offline {
            guard let match = index[asset.url.lastPathComponent.lowercased()] else { continue }
            applyRelink(id: asset.id, to: match)
            relinked += 1
        }
        if relinked > 0 { notifyTimelineChanged() }
        return (relinked, offline.count)
    }

    private func applyRelink(id: String, to newURL: URL) {
        guard let i = mediaAssets.firstIndex(where: { $0.id == id }) else { return }
        mediaAssets[i].url = newURL
        denoiseFailed.remove(id)
        denoiseBaked.remove(id)
        mediaVisualCache.invalidate(id)
        speakerAssignments.removeValue(forKey: id)
        if let j = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[j].source = mediaAssets[i].toManifestEntry(projectURL: projectURL).source
        }
        let asset = mediaAssets[i]
        Task { await finalizeImportedAsset(asset) }
    }

    /// Lowercased filename → URL for regular files under `folder`, first match wins.
    private func fileIndex(in folder: URL) -> [String: URL] {
        var map: [String: URL] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return map
        }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: keys))?.isRegularFile == true else { continue }
            let key = url.lastPathComponent.lowercased()
            if map[key] == nil { map[key] = url }
        }
        return map
    }
}
