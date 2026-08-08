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

        #expect(editor.selectAllClips(onTrack: "target"))
        #expect(editor.selectedClipIds == ["video", "title"])
    }

    @Test func unavailableTrackPreservesSelection() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "empty"),
        ])
        editor.selectedClipIds = ["existing"]

        #expect(!editor.selectAllClips(onTrack: "empty"))
        #expect(!editor.selectAllClips(onTrack: "missing"))
        #expect(editor.selectedClipIds == ["existing"])
    }
}
