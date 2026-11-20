import Foundation
import Testing
@testable import CompositorPro

@Suite("SourceTimeMap freeze")
struct FreezeTimeMapTests {
    @Test func noFreezeConsumesSourceUnchanged() {
        let map = SourceTimeMap(durationFrames: 100, speed: 2, frozenFrames: 0)
        #expect(map.sourceFramesConsumed == 200)
        #expect(map.segments.count == 1)
    }

    @Test func aFreezeReadsLessSourceUnlessTheLengthGrowsToMatch() {
        // A 20-frame hold at the head means only 80 frames of content play, so it reads less.
        #expect(SourceTimeMap(durationFrames: 100, speed: 2, frozenFrames: 20).sourceFramesConsumed == 160)
        // Growing the clip by the hold is what makes the freeze free: same source, same content.
        let compensated = SourceTimeMap(durationFrames: 120, speed: 2, frozenFrames: 20)
        #expect(compensated.sourceFramesConsumed == SourceTimeMap(durationFrames: 100, speed: 2).sourceFramesConsumed)
    }

    @Test func offsetsInsideTheHoldAllMapToTheFirstSourceFrame() {
        let map = SourceTimeMap(durationFrames: 100, speed: 2, frozenFrames: 20)
        #expect(map.sourceOffset(atTimelineOffset: 0) == 0)
        #expect(map.sourceOffset(atTimelineOffset: 10) == 0)
        #expect(map.sourceOffset(atTimelineOffset: 19) == 0)
        // Past the hold the rate resumes.
        #expect(map.sourceOffset(atTimelineOffset: 20) == 0)
        #expect(abs(map.sourceOffset(atTimelineOffset: 30) - 20) < 1e-9)
    }

    @Test func theHoldIsItsOwnSegmentScaledFromOneSourceFrame() {
        let map = SourceTimeMap(durationFrames: 100, speed: 2, frozenFrames: 20)
        let segments = map.segments
        #expect(segments.count == 2)
        #expect(segments[0].timelineRange == 0 ..< 20)
        #expect(segments[0].sourceSpan == 1)
        // One source frame stretched across the hold: the only way AVFoundation can hold.
        #expect(abs(segments[0].speed - 1.0 / 20.0) < 1e-9)
        #expect(segments[1].timelineRange == 20 ..< 100)
        #expect(abs(segments[1].speed - 2) < 1e-9)
    }

    @Test func segmentsStillTileTheClipWithAFreeze() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 1, interpolationOut: .linear))
        track.upsert(Keyframe(frame: 80, value: 4, interpolationOut: .linear))
        let map = SourceTimeMap(durationFrames: 100, speed: 1, track: track, frozenFrames: 15)
        let segments = map.segments
        #expect(segments.first?.timelineRange.lowerBound == 0)
        #expect(segments.last?.timelineRange.upperBound == 100)
        for index in 1 ..< segments.count {
            #expect(segments[index - 1].timelineRange.upperBound == segments[index].timelineRange.lowerBound)
        }
        #expect(segments.allSatisfy { $0.sourceSpan > 0 && $0.speed > 0 })
    }

    @Test func aFullyFrozenClipStillHasAValidSegment() {
        let map = SourceTimeMap(durationFrames: 10, speed: 1, frozenFrames: 10)
        #expect(map.segments.count == 1)
        #expect(map.segments[0].timelineRange == 0 ..< 10)
    }

    @Test func freezeFramesCannotExceedTheClip() {
        let map = SourceTimeMap(durationFrames: 30, speed: 1, frozenFrames: 99)
        #expect(map.frozenFrames == 30)
    }

    @Test func aFreezeDoesNotBreakRoundTripping() {
        let map = SourceTimeMap(durationFrames: 100, speed: 2, frozenFrames: 20)
        for offset in stride(from: 20, through: 100, by: 8) {
            let source = map.sourceOffset(atTimelineOffset: offset)
            let back = map.timelineOffset(forSourceOffset: source)
            #expect(abs(Double(back) - Double(offset)) <= 1)
        }
    }
}

@Suite("Clip freeze model")
struct ClipFreezeModelTests {
    @Test func freezeFramesRoundTripThroughJSON() throws {
        var clip = Fixtures.clip(id: "f", mediaRef: "m", start: 0, duration: 100)
        clip.freezeFrames = 20
        let decoded = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(clip))
        #expect(decoded.freezeFrames == 20)
    }

    @Test func anOldProjectDecodesWithNoFreeze() throws {
        let clip = Fixtures.clip(id: "f", mediaRef: "m", start: 0, duration: 100)
        let decoded = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(clip))
        #expect(decoded.freezeFrames == 0)
    }

    @Test func aFreezeCannotBeTheWholeClip() {
        var clip = Fixtures.clip(id: "f", mediaRef: "m", start: 0, duration: 10)
        clip.freezeFrames = 10
        clip.clampFreezeToDuration()
        #expect(clip.freezeFrames == 9)
    }

    @Test func rescalingTheLengthRescalesTheFreeze() {
        var clip = Fixtures.clip(id: "f", mediaRef: "m", start: 0, duration: 100)
        clip.freezeFrames = 20
        clip.setDuration(200)
        #expect(clip.freezeFrames == 40)
    }
}
