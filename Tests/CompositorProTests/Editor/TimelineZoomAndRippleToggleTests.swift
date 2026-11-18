import Foundation
import Testing
@testable import CompositorPro

@Suite("Timeline zoom and ripple toggles")
@MainActor
struct TimelineZoomAndRippleToggleTests {
    private func harness(frames: Int = 900) -> ToolHarness {
        let harness = ToolHarness()
        harness.editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 0, duration: 150),
                Fixtures.clip(id: "b", start: 150, duration: 150),
                Fixtures.clip(id: "c", start: 300, duration: 150),
            ]),
        ])
        harness.editor.timeline.fps = 30
        harness.editor.timelineVisibleWidth = 1_000
        return harness
    }

    @Test func fitTimelineUsesTheVisibleWidth() {
        let harness = harness()
        harness.editor.zoomToFitTimeline()
        let expected = 1_000 / Double(max(1, harness.editor.timeline.displayFrames))
        #expect(abs(harness.editor.zoomScale - expected) < 0.0001)
    }

    @Test func zoomToSelectionFitsTheSelectedSpan() {
        let harness = harness()
        harness.editor.selectedClipIds = ["b", "c"]
        harness.editor.zoomToSelection()
        // Span b..c = 300 frames wide.
        #expect(abs(harness.editor.zoomScale - (1_000 / 300)) < 0.0001)
        #expect(harness.editor.activeFrame == 150)
    }

    @Test func zoomMethodsIgnoreMissingGeometry() {
        let harness = harness()
        harness.editor.timelineVisibleWidth = 0
        let before = harness.editor.zoomScale
        harness.editor.zoomToFitTimeline()
        harness.editor.zoomToSelection()
        #expect(harness.editor.zoomScale == before)
    }

    @Test func rippleToggleMakesDeleteCloseTheGap() {
        let harness = harness()
        harness.editor.rippleEditingEnabled = true
        harness.editor.selectedClipIds = ["b"]
        harness.editor.deleteSelectedClips()
        let starts = harness.editor.timeline.tracks[0].clips.map(\.startFrame)
        #expect(starts == [0, 150])
        harness.editor.rippleEditingEnabled = false
    }

    @Test func plainDeleteKeepsPositionsWhenRippleIsOff() {
        let harness = harness()
        harness.editor.rippleEditingEnabled = false
        harness.editor.selectedClipIds = ["b"]
        harness.editor.deleteSelectedClips()
        let starts = harness.editor.timeline.tracks[0].clips.map(\.startFrame)
        #expect(starts == [0, 300])
    }
}
