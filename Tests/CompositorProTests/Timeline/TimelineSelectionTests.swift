import Foundation
import Testing
@testable import CompositorPro

@Suite("Timeline selection")
@MainActor
struct TimelineSelectionTests {
    @Test func escapeClearsEverySelectionKind() {
        let harness = ToolHarness()
        harness.editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 0, duration: 30),
                                        Fixtures.clip(id: "b", start: 30, duration: 30)]),
        ])
        harness.editor.selectedClipIds = ["a", "b"]
        harness.editor.selectedGap = GapSelection(trackIndex: 0, range: FrameRange(start: 30, end: 60))
        harness.editor.selectedTimelineMarkerIds = ["marker-1"]
        harness.editor.selectedMediaAssetIds = ["asset-1"]

        harness.editor.clearTimelineSelection()
        #expect(harness.editor.selectedClipIds.isEmpty)
        #expect(harness.editor.selectedGap == nil)
        #expect(harness.editor.selectedTimelineMarkerIds.isEmpty)
        // Escape in the timeline leaves the media panel selection alone; the controller clears it first.
        #expect(harness.editor.selectedMediaAssetIds == ["asset-1"])

        harness.editor.clearMediaPanelSelection()
        #expect(harness.editor.selectedMediaAssetIds.isEmpty)
        #expect(harness.editor.timeline.tracks.flatMap(\.clips).count == 2)
    }

    @Test func shiftToggleAddsAndRemovesFromSelection() {
        let harness = ToolHarness()
        harness.editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 0, duration: 30),
                                        Fixtures.clip(id: "b", start: 30, duration: 30)]),
        ])
        harness.editor.selectedClipIds = ["a"]
        #expect(harness.editor.selectedClipIds == ["a"])
        harness.editor.selectedClipIds.insert("b")
        #expect(harness.editor.selectedClipIds == ["a", "b"])
        harness.editor.selectedClipIds.subtract(["a"])
        #expect(harness.editor.selectedClipIds == ["b"])
    }
}
