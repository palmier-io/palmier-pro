import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor(_ tracks: [Track]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

private func spans(_ track: Track) -> [[Int]] {
    track.clips.sorted { $0.startFrame < $1.startFrame }.map { [$0.startFrame, $0.endFrame] }
}

@Suite("EditorViewModel — rippleTrimClip")
@MainActor
struct RippleTrimTests {

    @Test func rightExtendPushesDownstream() {
        // c1 has 50 frames of tail headroom; extend the out-point by 20 and c2 rides forward.
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
            Fixtures.clip(id: "c2", start: 100, duration: 50),
        ])
        let e = editor([track])
        e.rippleTrimClip(clipId: "c1", edge: .right, deltaFrames: 20, propagateToLinked: false)
        #expect(spans(e.timeline.tracks[0]) == [[0, 120], [120, 170]])
    }

    @Test func rightShrinkPullsDownstreamBack() {
        // Shrinking the out-point by 20 closes the gap: c2 slides left to stay contiguous.
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100),
            Fixtures.clip(id: "c2", start: 100, duration: 50),
        ])
        let e = editor([track])
        e.rippleTrimClip(clipId: "c1", edge: .right, deltaFrames: -20, propagateToLinked: false)
        #expect(spans(e.timeline.tracks[0]) == [[0, 80], [80, 130]])
    }

    @Test func extendNeverOverwritesFollowingClip() {
        // Without ripple this would overlap c2; ripple keeps every clip intact.
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100, trimEnd: 80),
            Fixtures.clip(id: "c2", start: 100, duration: 50),
        ])
        let e = editor([track])
        e.rippleTrimClip(clipId: "c1", edge: .right, deltaFrames: 60, propagateToLinked: false)
        #expect(spans(e.timeline.tracks[0]) == [[0, 160], [160, 210]])
    }

    @Test func leftRippleAnchorsStartAndShiftsDownstream() {
        // Head trim keeps the left edge butted at frame 0; the in-point reveals earlier source
        // and the duration delta ripples downstream.
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100, trimStart: 30),
            Fixtures.clip(id: "c2", start: 100, duration: 50),
        ])
        let e = editor([track])
        e.rippleTrimClip(clipId: "c1", edge: .left, deltaFrames: -20, propagateToLinked: false)
        #expect(spans(e.timeline.tracks[0]) == [[0, 120], [120, 170]])
        #expect(e.timeline.tracks[0].clips.first { $0.id == "c1" }?.trimStartFrame == 10)
    }

    @Test func linkedPartnerRipplesInSync() {
        // Video + linked audio extend together and each track's downstream clip rides forward.
        var v1 = Fixtures.clip(id: "v1", start: 0, duration: 100, trimEnd: 50)
        var a1 = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100, trimEnd: 50)
        v1.linkGroupId = "g"
        a1.linkGroupId = "g"
        let e = editor([
            Fixtures.videoTrack(clips: [v1, Fixtures.clip(id: "v2", start: 100, duration: 50)]),
            Fixtures.audioTrack(clips: [a1, Fixtures.clip(id: "a2", mediaType: .audio, start: 100, duration: 50)]),
        ])
        e.rippleTrimClip(clipId: "v1", edge: .right, deltaFrames: 20, propagateToLinked: true)
        #expect(spans(e.timeline.tracks[0]) == [[0, 120], [120, 170]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 120], [120, 170]])
    }

    @Test func linkedExtendClampsToMostConstrainedPartner() {
        // Video has 50 frames of tail headroom, audio only 10. A 20-frame extend binds to the
        // audio's limit so both grow by 10 and stay the same length.
        var v1 = Fixtures.clip(id: "v1", start: 0, duration: 100, trimEnd: 50)
        var a1 = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100, trimEnd: 10)
        v1.linkGroupId = "g"
        a1.linkGroupId = "g"
        let e = editor([
            Fixtures.videoTrack(clips: [v1, Fixtures.clip(id: "v2", start: 100, duration: 50)]),
            Fixtures.audioTrack(clips: [a1, Fixtures.clip(id: "a2", mediaType: .audio, start: 100, duration: 50)]),
        ])
        e.rippleTrimClip(clipId: "v1", edge: .right, deltaFrames: 20, propagateToLinked: true)
        #expect(spans(e.timeline.tracks[0]) == [[0, 110], [110, 160]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 110], [110, 160]])
    }

    @Test func planExposesDownstreamShiftsForPreview() {
        // The view previews from the same plan the commit applies: c2 shifts forward by 20.
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 100, trimEnd: 50),
            Fixtures.clip(id: "c2", start: 100, duration: 50),
        ])
        let e = editor([track])
        let plan = e.planRippleTrim(clipId: "c1", edge: .right, deltaFrames: 20, propagateToLinked: false)
        #expect(plan?.durationDelta == 20)
        #expect(plan?.shifts == [ClipShift(clipId: "c2", newStartFrame: 120)])
    }

    @Test func planClampsDeltaToConstrainedPartner() {
        // Preview must reflect the same source clamp as the commit (audio caps at 10).
        var v1 = Fixtures.clip(id: "v1", start: 0, duration: 100, trimEnd: 50)
        var a1 = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100, trimEnd: 10)
        v1.linkGroupId = "g"
        a1.linkGroupId = "g"
        let e = editor([
            Fixtures.videoTrack(clips: [v1]),
            Fixtures.audioTrack(clips: [a1]),
        ])
        let plan = e.planRippleTrim(clipId: "v1", edge: .right, deltaFrames: 20, propagateToLinked: true)
        #expect(plan?.durationDelta == 10)
    }

    @Test func unlinkedTrimLeavesPartnerTrackAlone() {
        // propagateToLinked off: only the lead's track ripples.
        var v1 = Fixtures.clip(id: "v1", start: 0, duration: 100, trimEnd: 50)
        var a1 = Fixtures.clip(id: "a1", mediaType: .audio, start: 0, duration: 100, trimEnd: 50)
        v1.linkGroupId = "g"
        a1.linkGroupId = "g"
        let e = editor([
            Fixtures.videoTrack(clips: [v1]),
            Fixtures.audioTrack(clips: [a1]),
        ])
        e.rippleTrimClip(clipId: "v1", edge: .right, deltaFrames: 20, propagateToLinked: false)
        #expect(spans(e.timeline.tracks[0]) == [[0, 120]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 100]])
    }
}
