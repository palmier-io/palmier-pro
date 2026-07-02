import Foundation

// Drag an external-source card onto the timeline (§ external-media-providers, Phase 4). The
// timeline drop path (TimelineView) resolves a pasteboard string into MediaAssets; these two
// helpers mirror assetsFromDragPayload for the `palmier-source://` scheme.
extension EditorViewModel {

    // Lightweight, UNregistered assets used only to size the drop ghost while dragging — no
    // import is kicked (avoids orphan downloads if the drag is cancelled).
    func sourceDragGhostAssets(from payload: String) -> [MediaAsset] {
        SourceDragPayload.decodeAll(payload).map { p in
            let type = p.assetType?.clipType ?? .video
            let asset = MediaAsset(id: "ghost-\(p.providerId)-\(p.ref)", url: URL(fileURLWithPath: "/"),
                                   type: type, name: p.name)
            asset.duration = p.durationSeconds > 0 ? p.durationSeconds : Defaults.imageDurationSeconds
            return asset
        }
    }

    // On drop: create a real downloading placeholder per card (registered + copy kicked) and
    // return them so the caller places clips. Skips cards that fail to resolve.
    func materializeSourceDragAssets(from payload: String) -> [MediaAsset] {
        let executor = ToolExecutor(editor: self)
        return SourceDragPayload.decodeAll(payload).compactMap { p in
            do {
                return try executor.makeProviderImport(
                    editor: self, providerId: p.providerId, ref: p.ref, name: p.name,
                    folderId: nil, typeHint: p.assetType,
                    placeholderDurationSeconds: p.durationSeconds
                )
            } catch {
                Log.project.error("source drag import failed provider=\(p.providerId) ref=\(p.ref): \(error.localizedDescription)")
                return nil
            }
        }
    }
}
