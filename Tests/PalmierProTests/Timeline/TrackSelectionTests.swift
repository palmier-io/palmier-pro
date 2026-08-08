import Testing
@testable import PalmierPro

@Suite("EditorViewModel — track selection")
@MainActor
struct TrackSelectionTests {
    @Test func selectsEveryClipOnTargetTrackOnly() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "target", clips: [
                Fixtures.clip(id: "video", mediaType: .video, start: 0, duration: 30),
                Fixtures.clip(id: "title", mediaType: .text, start: 30, duration: 30),
            ]),
            Fixtures.audioTrack(id: "other", clips: [
                Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 60),
            ]),
        ])
        editor.selectedClipIds = ["audio"]
        editor.selectedGap = GapSelection(
            trackIndex: 1,
            range: FrameRange(start: 60, end: 90)
        )

        #expect(editor.selectAllClips(onTrack: "target"))
        #expect(editor.selectedClipIds == ["video", "title"])
        #expect(editor.selectedGap == nil)
    }

    @Test func unavailableTrackPreservesSelection() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "empty"),
        ])
        editor.selectedClipIds = ["existing"]
        editor.selectedGap = GapSelection(
            trackIndex: 0,
            range: FrameRange(start: 0, end: 30)
        )

        #expect(!editor.selectAllClips(onTrack: "empty"))
        #expect(!editor.selectAllClips(onTrack: "missing"))
        #expect(editor.selectedClipIds == ["existing"])
        #expect(editor.selectedGap != nil)
    }
}
