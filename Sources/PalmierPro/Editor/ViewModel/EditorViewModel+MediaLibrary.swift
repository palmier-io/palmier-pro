import AppKit

/// Media library bookkeeping: import, rename, and manifest metadata sync for
/// the in-memory asset catalog and the persisted `MediaManifest`.
extension EditorViewModel {

    func importMediaAsset(_ asset: MediaAsset, skipAppend: Bool = false) {
        if !skipAppend {
            mediaAssets.append(asset)
        }
        let entry = asset.toManifestEntry(projectURL: projectURL)
        mediaManifest.entries.append(entry)
    }

    func renameMediaAsset(id: String, name: String) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        let oldName = asset.name
        asset.name = name
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[idx].name = name
        }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.renameMediaAsset(id: id, name: oldName)
        }
        undoManager?.setActionName("Rename Asset")
    }

    func updateManifestMetadata(for asset: MediaAsset) {
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
            mediaManifest.entries[idx].duration = asset.duration
            mediaManifest.entries[idx].sourceWidth = asset.sourceWidth
            mediaManifest.entries[idx].sourceHeight = asset.sourceHeight
            mediaManifest.entries[idx].sourceFPS = asset.sourceFPS
            mediaManifest.entries[idx].hasAudio = asset.hasAudio
        }
    }
}
