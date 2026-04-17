import AppKit

/// Preview-tab management: the timeline tab plus any media-asset source tabs
/// opened from the media library. Also hosts preview-specific computed props.
extension EditorViewModel {

    var activePreviewTab: PreviewTab {
        previewTabs.first { $0.id == activePreviewTabId } ?? .timeline
    }

    /// Minimum zoom scale that fits the entire timeline with end padding.
    var minZoomScale: Double {
        let totalFrames = timeline.totalFrames
        guard totalFrames > 0, timelineVisibleWidth > 0 else { return Zoom.min }
        let headerWidth = Double(Layout.trackHeaderWidth)
        let availableWidth = timelineVisibleWidth - headerWidth
        guard availableWidth > 0 else { return Zoom.min }
        return max(Zoom.min, availableWidth / (Double(totalFrames) * Zoom.fitAllBuffer))
    }

    var activePreviewDurationFrames: Int {
        switch activePreviewTab {
        case .timeline:
            return timeline.totalFrames
        case .mediaAsset(let id, _, _):
            guard let asset = mediaAssets.first(where: { $0.id == id }) else { return 0 }
            return secondsToFrame(seconds: asset.duration, fps: timeline.fps)
        }
    }

    func openPreviewTab(for asset: MediaAsset) {
        let tab = PreviewTab.mediaAsset(id: asset.id, name: asset.name, type: asset.type)
        if !previewTabs.contains(where: { $0.id == tab.id }) {
            previewTabs.append(tab)
        }
        activePreviewTabId = tab.id
        sourcePlayheadFrame = 0
        videoEngine?.activateTab(tab)
    }

    func closePreviewTab(id: String) {
        guard id != PreviewTab.timeline.id else { return }
        previewTabs.removeAll { $0.id == id }
        if activePreviewTabId == id {
            activePreviewTabId = PreviewTab.timeline.id
            videoEngine?.activateTab(.timeline)
        }
    }

    func selectPreviewTab(id: String) {
        guard previewTabs.contains(where: { $0.id == id }),
              activePreviewTabId != id else { return }
        activePreviewTabId = id
        videoEngine?.activateTab(activePreviewTab)
    }
}
