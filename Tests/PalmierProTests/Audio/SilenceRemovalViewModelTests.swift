import Foundation
import Testing
@testable import PalmierPro

@Suite("EditorViewModel — silence removal")
@MainActor
struct SilenceRemovalViewModelTests {

    @Test func silenceRemovalCandidateNilWhenNoSelection() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])])
        e.selectedClipIds = []
        #expect(e.silenceRemovalCandidate == nil)
    }

    @Test func silenceRemovalCandidateNilWhenMultipleSelected() {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 50),
            Fixtures.clip(id: "c2", start: 50, duration: 50),
        ])])
        e.selectedClipIds = ["c1", "c2"]
        #expect(e.silenceRemovalCandidate == nil)
    }

    @Test func silenceRemovalCandidateReturnsSingleVideoClip() {
        let e = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 100)
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        e.selectedClipIds = ["c1"]
        #expect(e.silenceRemovalCandidate?.id == "c1")
    }

    @Test func removeSilencesReturnedFramesRemovedViaRipple() {
        // Inject known silence ranges and verify they're removed.
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 300)])])
        let clip = e.timeline.tracks[0].clips[0]
        let silences: [(start: Double, end: Double)] = [(start: 1.0, end: 2.0)]  // 30 frames at 30fps
        let removed = e.removeSilences(clip: clip, silences: silences)
        #expect(removed == 30)
        #expect(e.timeline.tracks[0].endFrame == 270)
    }
}
