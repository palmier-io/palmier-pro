import Testing
@testable import PalmierPro

@Suite("EditorViewModel — preview selection")
@MainActor
struct PreviewSelectionTests {
    @Test func selectingClipClearsGapSelection() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "clip", start: 0, duration: 20)]),
        ])
        editor.selectedGap = GapSelection(trackIndex: 0, range: FrameRange(start: 50, end: 100))

        editor.selectPreviewClip("clip")

        #expect(editor.selectedClipIds == ["clip"])
        #expect(editor.selectedGap == nil)
    }

    @Test func selectingSelectedClipPreservesMultiSelection() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "first", start: 0, duration: 20),
                Fixtures.clip(id: "second", start: 100, duration: 20),
            ]),
        ])
        editor.selectedClipIds = ["first", "second"]

        editor.selectPreviewClip("first")

        #expect(editor.selectedClipIds == ["first", "second"])
    }
}
