import Testing
@testable import PalmierPro

@Suite("Timeline zoom")
@MainActor
struct TimelineZoomTests {
    @Test func minimumZoomUsesScrollableViewportWidth() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 100)]),
        ])
        editor.timelineVisibleWidth = 600

        #expect(editor.minZoomScale == 2)
    }
}
