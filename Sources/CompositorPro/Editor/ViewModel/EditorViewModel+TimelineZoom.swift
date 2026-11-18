import Foundation

extension EditorViewModel {
    /// Fits the whole timeline into the visible width.
    func zoomToFitTimeline() {
        let frames = max(1, timeline.displayFrames)
        guard timelineVisibleWidth > 0 else { return }
        setTimelineZoom(timelineVisibleWidth / Double(frames))
    }

    /// Fits the selected clips into the visible width and parks the playhead at their start.
    func zoomToSelection() {
        let selected = selectedClipIds.compactMap { clipFor(id: $0) }
        guard let first = selected.map(\.startFrame).min(),
              let last = selected.map(\.endFrame).max(),
              last > first,
              timelineVisibleWidth > 0 else { return }
        setTimelineZoom(timelineVisibleWidth / Double(last - first))
        playheadState.timelineFrame = first
    }

    private func setTimelineZoom(_ value: Double) {
        guard value.isFinite else { return }
        zoomScale = min(Zoom.max, max(minZoomScale, value))
    }
}
