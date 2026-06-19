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

private func spans(_ track: Track) -> [[Int]] {
    track.clips.sorted { $0.startFrame < $1.startFrame }.map { [$0.startFrame, $0.endFrame] }
}

@Suite("EditorViewModel — rippleDeleteRanges")
@MainActor
struct RippleDeleteRangesTests {

    @Test func cutsMidClipAndClosesGap() {
        // [0,100), remove [40,50): head [0,40) stays, tail slides left by 10 to meet it.
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])])
        let outcome = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        guard case .ok(let report) = outcome else { Issue.record("expected .ok"); return }
        #expect(report.removedFrames == 10)
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90]])
    }

    @Test func multipleRangesAccumulateShifts() {
        // [0,100), remove [20,30) and [60,70): three surviving pieces close up contiguously.
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])])
        let outcome = e.rippleDeleteRanges(
            anchorClipId: "c1",
            ranges: [FrameRange(start: 60, end: 70), FrameRange(start: 20, end: 30)]
        )
        guard case .ok(let report) = outcome else { Issue.record("expected .ok"); return }
        #expect(report.removedFrames == 20)
        #expect(spans(e.timeline.tracks[0]) == [[0, 20], [20, 50], [50, 80]])
    }

    @Test func overlappingRangesMergeBeforeCounting() {
        // Overlapping [40,55) and [50,70) merge to [40,70) = 30 frames removed, once.
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])])
        let outcome = e.rippleDeleteRanges(
            anchorClipId: "c1",
            ranges: [FrameRange(start: 40, end: 55), FrameRange(start: 50, end: 70)]
        )
        guard case .ok(let report) = outcome else { Issue.record("expected .ok"); return }
        #expect(report.removedFrames == 30)
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 70]])
    }

    @Test func downstreamClipShiftsByTotalRemoved() {
        // c2 sits after c1; removing 10 frames from c1 pulls c2 left by 10.
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100),
            Fixtures.clip(id: "c2", start: 100, duration: 50),
        ])
        let e = editor([track])
        _ = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        #expect(starts(e.timeline.tracks[0]) == [0, 40, 90])
    }

    @Test func linkedPartnerCutInSync() {
        // Video + linked audio occupy the same span; the cut applies to both tracks.
        var v1 = Fixtures.clip(id: "v1", start: 0, duration: 100)
        v1.linkGroupId = "G"
        var a1 = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100)
        a1.linkGroupId = "G"
        let e = editor([Fixtures.videoTrack(clips: [v1]), Fixtures.audioTrack(clips: [a1])])
        let outcome = e.rippleDeleteRanges(anchorClipId: "v1", ranges: [FrameRange(start: 40, end: 50)])
        guard case .ok(let report) = outcome else { Issue.record("expected .ok"); return }
        #expect(report.clearedTracks == 2)
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 40], [40, 90]])
    }

    @Test func syncLockedFollowerShifts() {
        // An unrelated sync-locked audio clip after the cut shifts along to stay aligned.
        let v = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])
        let a = Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", start: 120, duration: 30)])
        let e = editor([v, a])
        _ = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90]])
        #expect(starts(e.timeline.tracks[1]) == [110])
    }

    @Test func refusesWhenSyncLockedFollowerWouldCollide() {
        // a2 would slide left onto a1 → whole edit refused, nothing moves.
        let v = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])
        let a = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "a1", start: 0, duration: 95),
            Fixtures.clip(id: "a2", start: 100, duration: 50),
        ])
        let e = editor([v, a])
        let outcome = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        guard case .refused = outcome else { Issue.record("expected .refused"); return }
        #expect(spans(e.timeline.tracks[0]) == [[0, 100]])
        #expect(starts(e.timeline.tracks[1]) == [0, 100])
    }
}
