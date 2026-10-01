import Foundation
import Testing
@testable import CompositorPro

@Suite("SourceTimeMap")
struct SourceTimeMapTests {
    /// The contract that keeps every existing call site correct: a constant-speed clip must
    /// consume exactly what the old `durationFrames * speed` formula consumed.
    @Test(arguments: [1, 2, 5, 30, 120, 4800])
    func constantSpeedMatchesTheHistoricalScalar(duration: Int) {
        for speed in [0.25, 0.5, 1.0, 1.5, 2.0, 3.7, 4.0] {
            let map = SourceTimeMap(durationFrames: duration, speed: speed)
            #expect(map.isConstantSpeed)
            #expect(map.sourceFramesConsumed == Int((Double(duration) * speed).rounded()))
            #expect(map.averageSpeed == speed)
            #expect(map.speed(atOffset: 0) == speed)
            #expect(map.speed(atOffset: duration * 2) == speed)
        }
    }

    @Test func constantSpeedSourceOffsetIsLinear() {
        let map = SourceTimeMap(durationFrames: 100, speed: 2)
        #expect(map.sourceOffset(atTimelineOffset: 0) == 0)
        #expect(map.sourceOffset(atTimelineOffset: 25) == 50)
        #expect(map.sourceOffset(atTimelineOffset: 100) == 200)
    }

    @Test func constantSpeedRoundTripsThroughBothDirections() {
        let map = SourceTimeMap(durationFrames: 300, speed: 1.75)
        for offset in stride(from: 0, through: 300, by: 7) {
            let source = map.sourceOffset(atTimelineOffset: offset)
            #expect(abs(Double(map.timelineOffset(forSourceOffset: source)) - Double(offset)) <= 1)
        }
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity, 1e9])
    func outOfRangeSpeedIsClampedToTheSupportedBand(input: Double) {
        let map = SourceTimeMap(durationFrames: 60, speed: input)
        #expect(map.averageSpeed >= SourceTimeMap.minimumSpeed)
        #expect(map.averageSpeed <= SourceTimeMap.maximumSpeed)
        #expect(map.averageSpeed.isFinite)
    }

    @Test func aSingleKeyframeTrackIsTreatedAsConstant() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 30, value: 4))
        let map = SourceTimeMap(durationFrames: 100, speed: 1, track: track)
        #expect(map.isConstantSpeed)
        #expect(map.averageSpeed == 1)
    }

    @Test func rampIntegratesAsTheAreaUnderTheCurve() {
        // 0→2x over 100 frames: the mean is 1.5, so 150 source frames are consumed.
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 1))
        track.upsert(Keyframe(frame: 100, value: 2))
        let map = SourceTimeMap(durationFrames: 100, speed: 1, track: track)
        #expect(!map.isConstantSpeed)
        #expect(abs(map.averageSpeed - 1.5) < 1e-9)
        #expect(map.sourceFramesConsumed == 150)
        // Half the span holds the lower half of the ramp, so its mean is 1.25.
        #expect(abs(map.sourceOffset(atTimelineOffset: 50) - 62.5) < 1e-9)
    }

    @Test func slowDownRampConsumesLessSource() {
        // 4x → 1x over 100 frames: mean 2.5, 250 source frames.
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 4))
        track.upsert(Keyframe(frame: 100, value: 1))
        let map = SourceTimeMap(durationFrames: 100, speed: 4, track: track)
        #expect(abs(map.averageSpeed - 2.5) < 1e-9)
        #expect(map.sourceFramesConsumed == 250)
    }

    @Test func speedHoldsAfterTheLastKeyframe() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 1))
        track.upsert(Keyframe(frame: 40, value: 2))
        let map = SourceTimeMap(durationFrames: 100, speed: 1, track: track)
        #expect(map.speed(atOffset: 40) == 2)
        #expect(map.speed(atOffset: 99) == 2)
        // 0–40 ramps 1→2 (60 source), 40–100 holds 2 (120 source).
        #expect(abs(map.sourceOffset(atTimelineOffset: 100) - 180) < 1e-9)
    }

    @Test func keyframeBeforeZeroOrAfterDurationIsIgnored() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: -10, value: 8))
        track.upsert(Keyframe(frame: 0, value: 1))
        track.upsert(Keyframe(frame: 50, value: 2))
        track.upsert(Keyframe(frame: 500, value: 9))
        let map = SourceTimeMap(durationFrames: 100, speed: 1, track: track)
        #expect(map.speed(atOffset: 0) == 1)
        #expect(map.speed(atOffset: 100) == 2)
    }

    @Test func speedSamplesMatchTheKeyframeInterpolation() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 1, interpolationOut: .linear))
        track.upsert(Keyframe(frame: 100, value: 3, interpolationOut: .linear))
        let map = SourceTimeMap(durationFrames: 100, speed: 1, track: track)
        #expect(abs(map.speed(atOffset: 50) - 2) < 1e-9)
        #expect(abs(map.speed(atOffset: 25) - 1.5) < 1e-9)
        #expect(abs(map.speed(atOffset: 75) - 2.5) < 1e-9)
    }

    @Test func rampInverseRecoversTheTimelineOffset() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 1, interpolationOut: .linear))
        track.upsert(Keyframe(frame: 100, value: 4, interpolationOut: .linear))
        let map = SourceTimeMap(durationFrames: 100, speed: 1, track: track)
        for offset in stride(from: 0, through: 100, by: 5) {
            let source = map.sourceOffset(atTimelineOffset: offset)
            #expect(abs(Double(map.timelineOffset(forSourceOffset: source)) - Double(offset)) <= 1)
        }
    }

    @Test func inverseClampsToTheClipSpan() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 2))
        track.upsert(Keyframe(frame: 100, value: 2))
        let map = SourceTimeMap(durationFrames: 100, speed: 2, track: track)
        #expect(map.timelineOffset(forSourceOffset: -50) == 0)
        #expect(map.timelineOffset(forSourceOffset: 10_000) == 100)
    }

    @Test func segmentsTileTheClipAndSumToTheConsumedSource() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 1, interpolationOut: .linear))
        track.upsert(Keyframe(frame: 50, value: 3, interpolationOut: .linear))
        track.upsert(Keyframe(frame: 120, value: 1, interpolationOut: .linear))
        let map = SourceTimeMap(durationFrames: 120, speed: 1, track: track)
        let segments = map.segments
        #expect(segments.first?.timelineRange.lowerBound == 0)
        #expect(segments.last?.timelineRange.upperBound == 120)
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                #expect(segments[index - 1].timelineRange.upperBound == segment.timelineRange.lowerBound)
            }
            #expect(segment.speed > 0)
            #expect(segment.sourceSpan > 0)
        }
        let total = segments.reduce(0.0) { $0 + $1.sourceSpan }
        #expect(abs(total - map.sourceOffset(atTimelineOffset: 120)) < 1e-6)
    }

    @Test func segmentsCoverTheTailAfterTheLastKeyframe() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 1, interpolationOut: .linear))
        track.upsert(Keyframe(frame: 30, value: 4, interpolationOut: .linear))
        let map = SourceTimeMap(durationFrames: 90, speed: 1, track: track)
        let segments = map.segments
        #expect(segments.count == 2)
        #expect(segments[0].timelineRange == 0 ..< 30)
        #expect(segments[1].timelineRange == 30 ..< 90)
        #expect(abs(segments[1].speed - 4) < 1e-9)
    }

    @Test func constantSpeedIsASingleSegment() {
        let map = SourceTimeMap(durationFrames: 120, speed: 2)
        #expect(map.segments.count == 1)
        #expect(map.segments[0].timelineRange == 0 ..< 120)
        #expect(map.segments[0].sourceSpan == 240)
    }

    @Test func zeroDurationProducesNoSegments() {
        #expect(SourceTimeMap(durationFrames: 0, speed: 2).segments.isEmpty)
        #expect(SourceTimeMap(durationFrames: 0, speed: 2).sourceFramesConsumed == 0)
        #expect(SourceTimeMap(durationFrames: 0, speed: 2).timelineOffset(forSourceOffset: 10) == 0)
    }

    /// A clip that slows to a crawl and back must not let the integral fall below one source
    /// frame per output frame, or the composition build would ask for an empty time range.
    @Test func minimumSpeedKeepsEverySegmentPositive() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: SourceTimeMap.minimumSpeed))
        track.upsert(Keyframe(frame: 50, value: SourceTimeMap.minimumSpeed))
        let map = SourceTimeMap(durationFrames: 50, speed: SourceTimeMap.minimumSpeed, track: track)
        #expect(map.segments.allSatisfy { $0.sourceSpan > 0 })
        #expect(map.segments.allSatisfy { $0.speed >= SourceTimeMap.minimumSpeed })
    }
}
