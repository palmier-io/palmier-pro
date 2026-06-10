import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor(_ tracks: [Track]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

private func starts(_ track: Track) -> [Int] {
    track.clips.sorted { $0.startFrame < $1.startFrame }.map(\.startFrame)
}

@Suite("EditorViewModel — rippleDeleteSelectedGap")
@MainActor
struct RippleGapDeleteTests {

    @Test func closesGapAndClearsSelection() {
        // V1: [0,50) _gap_ [100,150). Deleting the gap pulls c2 to 50.
        let c1 = Fixtures.clip(id: "c1", start: 0, duration: 50)
        let c2 = Fixtures.clip(id: "c2", start: 100, duration: 50)
        let e = editor([Fixtures.videoTrack(clips: [c1, c2])])
        e.selectedGap = GapSelection(trackIndex: 0, range: FrameRange(start: 50, end: 100))
        e.rippleDeleteSelectedGap()
        #expect(starts(e.timeline.tracks[0]) == [0, 50])
        #expect(e.selectedGap == nil)
    }

    @Test func syncLockedTrackFollows() {
        // Gap on V1 also shifts a clip after it on a sync-locked audio track.
        let v = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 50),
                                            Fixtures.clip(id: "c2", start: 100, duration: 50)])
        let a = Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", start: 120, duration: 30)])
        let e = editor([v, a])
        e.selectedGap = GapSelection(trackIndex: 0, range: FrameRange(start: 50, end: 100))
        e.rippleDeleteSelectedGap()
        #expect(starts(e.timeline.tracks[0]) == [0, 50])
        #expect(starts(e.timeline.tracks[1]) == [70])
    }

    @Test func refusesWhenSyncLockedFollowerWouldCollide() {
        // a2 (at/after the gap end) shifts left by 50 onto a1 → whole edit refused, nothing moves.
        let v = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 50),
                                            Fixtures.clip(id: "c2", start: 100, duration: 50)])
        let a = Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", start: 0, duration: 55),
                                            Fixtures.clip(id: "a2", start: 100, duration: 50)])
        let e = editor([v, a])
        e.selectedGap = GapSelection(trackIndex: 0, range: FrameRange(start: 50, end: 100))
        e.rippleDeleteSelectedGap()
        #expect(starts(e.timeline.tracks[0]) == [0, 100])
        #expect(starts(e.timeline.tracks[1]) == [0, 100])
    }

    @Test func noOpWhenGapNoLongerEmpty() {
        // A stale selection whose range a clip now occupies must not shift anything.
        let v = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 50),
                                            Fixtures.clip(id: "c3", start: 60, duration: 30),
                                            Fixtures.clip(id: "c2", start: 100, duration: 50)])
        let e = editor([v])
        e.selectedGap = GapSelection(trackIndex: 0, range: FrameRange(start: 50, end: 100))
        e.rippleDeleteSelectedGap()
        #expect(starts(e.timeline.tracks[0]) == [0, 60, 100])
        #expect(e.selectedGap == nil)
    }
}
