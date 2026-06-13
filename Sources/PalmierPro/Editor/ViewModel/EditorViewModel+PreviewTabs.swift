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
        let fitAll = availableWidth / (Double(totalFrames) * Zoom.fitAllBuffer)
        return min(Zoom.max, max(Zoom.floor, fitAll))
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

    func selectMediaAsset(_ asset: MediaAsset, atSourceFrame frame: Int = 0) {
        openPreviewTab(for: asset, atSourceFrame: frame)
        syncSelectionToActiveTab()
        showMediaPanelMediaTab()
    }

    func openPreviewTab(for asset: MediaAsset, atSourceFrame frame: Int = 0) {
        let tab = PreviewTab.mediaAsset(id: asset.id, name: asset.name, type: asset.type)
        if !previewTabs.contains(where: { $0.id == tab.id }) {
            previewTabs.append(tab)
        }
        activePreviewTabId = tab.id
        sourcePlayheadFrame = frame
        videoEngine?.activateTab(tab)
        pushPreviewHistory(tab.id)
    }

    func closePreviewTab(id: String) {
        guard id != PreviewTab.timeline.id else { return }
        previewTabs.removeAll { $0.id == id }
        previewTabHistory.removeAll { $0 == id }
        if previewTabHistory.isEmpty {
            previewTabHistory = [PreviewTab.timeline.id]
        }
        previewTabHistoryIndex = min(previewTabHistoryIndex, previewTabHistory.count - 1)
        if activePreviewTabId == id {
            let fallbackId = previewTabHistory[previewTabHistoryIndex]
            activePreviewTabId = fallbackId
            videoEngine?.activateTab(activePreviewTab)
        }
    }

    func selectPreviewTab(id: String) {
        guard previewTabs.contains(where: { $0.id == id }),
              activePreviewTabId != id else { return }
        activePreviewTabId = id
        videoEngine?.activateTab(activePreviewTab)
        syncSelectionToActiveTab()
        pushPreviewHistory(id)
    }

    // MARK: - Tab history (back/forward navigation)

    var canGoBackPreviewTab: Bool { previewTabHistoryIndex > 0 }
    var canGoForwardPreviewTab: Bool { previewTabHistoryIndex < previewTabHistory.count - 1 }

    func goBackPreviewTab() { stepPreviewHistory(-1) }
    func goForwardPreviewTab() { stepPreviewHistory(1) }

    func closeAllPreviewTabs() {
        previewTabs = [.timeline]
        activePreviewTabId = PreviewTab.timeline.id
        previewTabHistory = [PreviewTab.timeline.id]
        previewTabHistoryIndex = 0
        videoEngine?.activateTab(.timeline)
    }

    private func stepPreviewHistory(_ delta: Int) {
        let next = previewTabHistoryIndex + delta
        guard previewTabHistory.indices.contains(next) else { return }
        previewTabHistoryIndex = next
        let id = previewTabHistory[next]
        guard activePreviewTabId != id else { return }
        activePreviewTabId = id
        videoEngine?.activateTab(activePreviewTab)
        syncSelectionToActiveTab()
    }

    private func syncSelectionToActiveTab() {
        switch activePreviewTab {
        case .timeline:
            selectedMediaAssetIds.removeAll()
        case .mediaAsset(let id, _, _):
            selectedClipIds.removeAll()
            selectedFolderIds.removeAll()
            selectedMediaAssetIds = [id]
        }
    }

    private func pushPreviewHistory(_ id: String) {
        let tail = previewTabHistoryIndex + 1
        if tail < previewTabHistory.count {
            previewTabHistory.removeSubrange(tail...)
        }
        guard previewTabHistory.last != id else { return }
        previewTabHistory.append(id)
        previewTabHistoryIndex = previewTabHistory.count - 1
    }
}
