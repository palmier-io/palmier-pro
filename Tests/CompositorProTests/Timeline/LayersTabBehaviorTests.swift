import Foundation
import Testing
@testable import CompositorPro

@Suite("Layers tab behavior")
@MainActor
struct LayersTabBehaviorTests {
    private func harness() -> ToolHarness {
        let harness = ToolHarness()
        harness.editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "v1", start: 0, duration: 30)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "v2", start: 0, duration: 30)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 30)]),
        ])
        return harness
    }

    @Test func visibilityAndMuteTogglesFlipTheTrack() {
        let harness = harness()
        harness.editor.toggleTrackHidden(trackIndex: 0)
        #expect(harness.editor.timeline.tracks[0].hidden)
        harness.editor.toggleTrackHidden(trackIndex: 0)
        #expect(!harness.editor.timeline.tracks[0].hidden)

        let audioIndex = harness.editor.timeline.tracks.firstIndex { $0.type == .audio }!
        harness.editor.toggleTrackMute(trackIndex: audioIndex)
        #expect(harness.editor.timeline.tracks[audioIndex].muted)
    }

    @Test func reorderingMovesTheTrack() {
        let harness = harness()
        let movedId = harness.editor.timeline.tracks[0].id
        harness.editor.reorderTrackLive(id: movedId, to: 1)
        #expect(harness.editor.timeline.tracks[1].id == movedId)
    }

    @Test func selectingATrackRowSelectsItsClips() {
        let harness = harness()
        harness.editor.selectedClipIds = Set(harness.editor.timeline.tracks[1].clips.map(\.id))
        #expect(harness.editor.selectedClipIds == ["v2"])
    }
}
