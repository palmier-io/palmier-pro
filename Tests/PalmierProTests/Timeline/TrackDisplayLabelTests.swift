import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func makeEditor(_ tracks: [Track]) -> EditorViewModel {
    let editor = EditorViewModel()
    editor.timeline = Fixtures.timeline(tracks: tracks)
    return editor
}

@Suite("EditorViewModel — track display label")
@MainActor
struct TrackDisplayLabelTests {

    @Test func labelsVisualTracksTopToBottomThenAudio() {
        let editor = makeEditor([
            Fixtures.videoTrack(),
            Fixtures.videoTrack(),
            Fixtures.audioTrack(),
        ])
        #expect(editor.timelineTrackDisplayLabel(at: 0) == "V2")
        #expect(editor.timelineTrackDisplayLabel(at: 1) == "V1")
        #expect(editor.timelineTrackDisplayLabel(at: 2) == "A1")
    }

    @Test func outOfRangeIndexReturnsEmpty() {
        let editor = makeEditor([Fixtures.videoTrack()])
        #expect(editor.timelineTrackDisplayLabel(at: 5) == "")
    }

    @Test func visualTrackAfterAudioDoesNotTrap() {
        // Invariant-violating order (visual below audio) — must not crash on the empty range.
        var text = Fixtures.videoTrack()
        text.type = .text
        let editor = makeEditor([
            Fixtures.videoTrack(),
            Fixtures.audioTrack(),
            text,
        ])
        #expect(editor.timelineTrackDisplayLabel(at: 2) == "T1")
    }
}
