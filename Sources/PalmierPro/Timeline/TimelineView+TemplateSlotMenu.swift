import AppKit

extension TimelineView {
    /// Menu items for filling a template slot from the media panel selection.
    func templateSlotMenuItems(for clip: Clip) -> [NSMenuItem] {
        guard clip.templateSlot != nil else { return [] }

        let selectedVideos = editor.mediaAssets.filter {
            editor.selectedMediaAssetIds.contains($0.id) && $0.type == .video
        }
        guard selectedVideos.count == 1, let asset = selectedVideos.first else {
            let item = NSMenuItem(
                title: L10n.string("Replace Slot with Selected Media"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            item.toolTip = L10n.string("Select one video in the media panel first.")
            return [item]
        }

        let item = NSMenuItem(
            title: L10n.string("Replace Slot with \"\(asset.name)\""),
            action: #selector(performFillTemplateSlot(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = TemplateSlotFillRequest(clipId: clip.id, assetId: asset.id)
        return [item]
    }

    @objc func performFillTemplateSlot(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? TemplateSlotFillRequest else { return }
        do {
            try editor.fillTemplateSlot(clipId: request.clipId, assetId: request.assetId)
        } catch {
            editor.mediaPanelToast = MediaPanelToast(message: error.localizedDescription, kind: .warning)
        }
    }
}

final class TemplateSlotFillRequest: NSObject {
    let clipId: String
    let assetId: String

    init(clipId: String, assetId: String) {
        self.clipId = clipId
        self.assetId = assetId
    }
}
