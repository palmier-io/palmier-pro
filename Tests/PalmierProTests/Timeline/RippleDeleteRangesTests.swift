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

    @Test func syncLockedFollowerCutInSync() {
        // Master audio spanning the same span as video gets the cut, not just a shift.
        let v = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])
        let a = Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", start: 0, duration: 100)])
        let e = editor([v, a])
        let outcome = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        guard case .ok(let report) = outcome else { Issue.record("expected .ok"); return }
        #expect(report.clearedTracks == 2)
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 40], [40, 90]])
    }

    @Test func trackWideCutSpansMultipleClips() {
        // Two contiguous clips on one track; one call removes a range from each and closes both gaps.
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100),
            Fixtures.clip(id: "c2", start: 100, duration: 100),
        ])
        let e = editor([track])
        let outcome = e.rippleDeleteRangesOnTrack(
            trackIndex: 0,
            ranges: [FrameRange(start: 40, end: 50), FrameRange(start: 150, end: 160)]
        )
        guard case .ok(let report) = outcome else { Issue.record("expected .ok"); return }
        #expect(report.removedFrames == 20)
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90], [90, 140], [140, 180]])
    }

    @Test func trackWideCutSyncsLinkedPartnersOfEachClip() {
        // Each video clip has its own linked audio partner; a track-wide cut keeps both in sync.
        var v1 = Fixtures.clip(id: "v1", start: 0, duration: 100); v1.linkGroupId = "G1"
        var v2 = Fixtures.clip(id: "v2", start: 100, duration: 100); v2.linkGroupId = "G2"
        var a1 = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100); a1.linkGroupId = "G1"
        var a2 = Fixtures.clip(id: "a2", mediaType: .audio, start: 100, duration: 100); a2.linkGroupId = "G2"
        let e = editor([Fixtures.videoTrack(clips: [v1, v2]), Fixtures.audioTrack(clips: [a1, a2])])
        let outcome = e.rippleDeleteRangesOnTrack(
            trackIndex: 0,
            ranges: [FrameRange(start: 40, end: 50), FrameRange(start: 150, end: 160)]
        )
        guard case .ok(let report) = outcome else { Issue.record("expected .ok"); return }
        #expect(report.clearedTracks == 2)
        #expect(spans(e.timeline.tracks[0]) == spans(e.timeline.tracks[1]))
    }

    @Test func linkedPartnerOnSyncLockOffTrackCutInSync() {
        // Cut anchored on an unrelated track: the sync-locked audio a1 is cleared, so its
        // linked video v1 must be cut too even though v1's track has sync lock off.
        var v1 = Fixtures.clip(id: "v1", start: 0, duration: 100); v1.linkGroupId = "G"
        var a1 = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100); a1.linkGroupId = "G"
        let r1 = Fixtures.clip(id: "r1", mediaType: .audio, start: 0, duration: 100)
        let e = editor([
            Fixtures.videoTrack(clips: [v1]),
            Fixtures.audioTrack(clips: [a1]),
            Fixtures.audioTrack(clips: [r1]),
        ])
        e.timeline.tracks[0].syncLocked = false
        let outcome = e.rippleDeleteRangesOnTrack(trackIndex: 2, ranges: [FrameRange(start: 40, end: 50)])
        guard case .ok(let report) = outcome else { Issue.record("expected .ok"); return }
        #expect(report.clearedTracks == 3)
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 40], [40, 90]])
        #expect(spans(e.timeline.tracks[2]) == [[0, 40], [40, 90]])
    }

    @Test func rippleInsertPushesDownstream() {
        // c1 [0,50), c2 [50,100). Insert a 30-frame asset at 50 → c2 pushed to [80,130).
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 50),
            Fixtures.clip(id: "c2", start: 50, duration: 50),
        ])
        let e = editor([track])
        let asset = MediaAsset(id: "m1", url: URL(fileURLWithPath: "/tmp/m1.mov"), type: .video, name: "m1", duration: 1.0)
        asset.hasAudio = false
        e.mediaAssets.append(asset)
        let created = e.rippleInsertClips(assets: [asset], trackIndex: 0, atFrame: 50)
        #expect(created.count == 1)
        let s = spans(e.timeline.tracks[0])
        #expect(s.contains([0, 50]))
        #expect(s.contains([50, 80]))
        #expect(s.contains([80, 130]))
    }

    @Test func syncLockedFollowerCutAvoidsShiftCollision() {
        // a1 is trimmed by the cut so a2 can shift left without overlapping.
        let v = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])
        let a = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "a1", start: 0, duration: 95),
            Fixtures.clip(id: "a2", start: 100, duration: 50),
        ])
        let e = editor([v, a])
        let outcome = e.rippleDeleteRanges(anchorClipId: "c1", ranges: [FrameRange(start: 40, end: 50)])
        guard case .ok = outcome else { Issue.record("expected .ok"); return }
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 40], [40, 85], [90, 140]])
    }

    @Test func ignoreSyncLockedTracksLetsCutProceedAndLeavesThemInPlace() {
        // Same collision as above, but exempting the blocking track lets the cut run;
        // the anchor closes its gap while the exempted track's clips stay put.
        let v = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])
        let a = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "a1", start: 0, duration: 95),
            Fixtures.clip(id: "a2", start: 100, duration: 50),
        ])
        let e = editor([v, a])
        let outcome = e.rippleDeleteRangesOnTrack(
            trackIndex: 0,
            ranges: [FrameRange(start: 40, end: 50)],
            ignoreSyncLockTrackIndices: [1]
        )
        guard case .ok = outcome else { Issue.record("expected .ok"); return }
        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90]])
        #expect(starts(e.timeline.tracks[1]) == [0, 100])
    }
}
