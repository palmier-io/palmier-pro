import Foundation

// Armed swap session: pick a replacement source from the media panel for a clip, preserving its state.
extension EditorViewModel {
    var pendingSwapClip: Clip? {
        guard let id = pendingSwapClipId, let loc = findClip(id: id) else { return nil }
        return timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
    }

    var pendingSwapClipName: String? {
        guard let clip = pendingSwapClip else { return nil }
        return mediaAssets.first { $0.id == clip.mediaRef }?.name
    }

    func beginMediaSwap(clipId: String) {
        guard findClip(id: clipId) != nil else { return }
        pendingSwapClipId = clipId
        showMediaPanelMediaTab()
    }

    func cancelMediaSwap() {
        pendingSwapClipId = nil
    }

    func isAssetCompatibleWithPendingSwap(_ asset: MediaAsset) -> Bool {
        guard let clip = pendingSwapClip else { return false }
        return clip.mediaType == asset.type
    }

    func completeMediaSwap(with asset: MediaAsset) {
        guard let clip = pendingSwapClip else { pendingSwapClipId = nil; return }
        guard clip.mediaType == asset.type else {
            mediaPanelToast = "Can't swap — pick \(clip.mediaType.trackLabel.lowercased()) media to replace this clip."
            return
        }
        pendingSwapClipId = nil
        guard asset.id != clip.mediaRef else { return }
        replaceClipMediaRef(clipId: clip.id, newAssetId: asset.id)
    }
}
