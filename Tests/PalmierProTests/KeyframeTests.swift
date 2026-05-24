import Testing
@testable import PalmierPro

@Suite("KeyframeTrack mutations")
struct KeyframeTrackMutationTests {

    @Test func upsertIntoEmptyAppends() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 10, value: 1.0))
        #expect(track.keyframes.count == 1)
        #expect(track.keyframes[0].frame == 10)
        #expect(track.isActive)
    }

    @Test func upsertMaintainsSortedOrder() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 20, value: 2.0))
        track.upsert(Keyframe(frame: 5, value: 0.5))
        track.upsert(Keyframe(frame: 10, value: 1.0))
        #expect(track.keyframes.map(\.frame) == [5, 10, 20])
    }

    @Test func upsertReplacesKeyframeAtSameFrame() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 10, value: 1.0))
        track.upsert(Keyframe(frame: 10, value: 99.0))
        #expect(track.keyframes.count == 1)
        #expect(track.keyframes[0].value == 99.0)
    }

    @Test func removeDeletesAtFrame() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 5, value: 0.5))
        track.upsert(Keyframe(frame: 10, value: 1.0))
        track.remove(at: 5)
        #expect(track.keyframes.map(\.frame) == [10])
    }

    @Test func removeAtMissingFrameIsNoOp() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 10, value: 1.0))
        track.remove(at: 99)
        #expect(track.keyframes.count == 1)
    }

    @Test func emptyTrackIsNotActive() {
        let track = KeyframeTrack<Double>()
        #expect(!track.isActive)
    }

    @Test func moveRelocatesKeyframeAndMaintainsOrder() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 5, value: 0.5))
        track.upsert(Keyframe(frame: 10, value: 1.0))
        track.upsert(Keyframe(frame: 20, value: 2.0))
        track.move(from: 5, to: 15) // 0.5 moves between 1.0 and 2.0
        #expect(track.keyframes.map(\.frame) == [10, 15, 20])
        #expect(track.keyframes[1].value == 0.5)
    }

    @Test func moveFromMissingFrameIsNoOp() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 10, value: 1.0))
        track.move(from: 99, to: 5)
        #expect(track.keyframes.map(\.frame) == [10])
    }

    @Test func moveOntoExistingFrameReplacesIt() {
        // move() calls upsert(), and upsert replaces on same-frame collisions.
        // The moved kf's value wins; the previous occupant is dropped.
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 5, value: 0.5))
        track.upsert(Keyframe(frame: 10, value: 1.0))
        track.move(from: 5, to: 10)
        #expect(track.keyframes.count == 1)
        #expect(track.keyframes[0].frame == 10)
        #expect(track.keyframes[0].value == 0.5) // the moved one wins
    }
}

@Suite("KeyframeTrack.sample")
struct KeyframeTrackSampleTests {

    @Test func emptyTrackReturnsFallback() {
        let track = KeyframeTrack<Double>()
        #expect(track.sample(at: 10, fallback: 42.0) == 42.0)
    }

    @Test func singleKeyframeReturnsItsValueEverywhere() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 10, value: 7.0))
        #expect(track.sample(at: 0, fallback: 0) == 7.0)
        #expect(track.sample(at: 10, fallback: 0) == 7.0)
        #expect(track.sample(at: 100, fallback: 0) == 7.0)
    }

    @Test func samplesBeforeFirstClampToFirstValue() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 10, value: 1.0))
        track.upsert(Keyframe(frame: 20, value: 2.0))
        #expect(track.sample(at: 5, fallback: 0) == 1.0)
        #expect(track.sample(at: 10, fallback: 0) == 1.0)
    }

    @Test func samplesAfterLastClampToLastValue() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 10, value: 1.0))
        track.upsert(Keyframe(frame: 20, value: 2.0))
        #expect(track.sample(at: 20, fallback: 0) == 2.0)
        #expect(track.sample(at: 100, fallback: 0) == 2.0)
    }

    @Test func linearInterpolatesBetweenKeyframes() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 0, interpolationOut: .linear))
        track.upsert(Keyframe(frame: 10, value: 10))
        #expect(track.sample(at: 3, fallback: 0) == 3.0)
        #expect(track.sample(at: 5, fallback: 0) == 5.0)
        #expect(track.sample(at: 7, fallback: 0) == 7.0)
    }

    @Test func holdReturnsLeftKeyframeUntilNextStarts() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 0, interpolationOut: .hold))
        track.upsert(Keyframe(frame: 10, value: 10))
        // Anywhere inside the segment, hold returns the left kf's value.
        #expect(track.sample(at: 1, fallback: 0) == 0.0)
        #expect(track.sample(at: 9, fallback: 0) == 0.0)
        // At/after the next kf, that one's clamp branch returns its value.
        #expect(track.sample(at: 10, fallback: 0) == 10.0)
    }

    @Test func smoothUsesSmoothstepEasing() {
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 0, interpolationOut: .smooth))
        track.upsert(Keyframe(frame: 10, value: 10))
        // smoothstep(0.5) = 0.5 → same as linear at midpoint.
        #expect(track.sample(at: 5, fallback: 0) == 5.0)
        // smoothstep(0.1) = 0.028 → 0.28. Easing is slower at the ends than linear (would be 1.0).
        let early = track.sample(at: 1, fallback: 0)
        #expect(early < 1.0)
        #expect(early > 0)
    }

    @Test func interpolationOutBelongsToLeftKeyframe() {
        // The interpolation on the SECOND kf doesn't affect the segment between first and second.
        var track = KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: 0, value: 0, interpolationOut: .linear))
        track.upsert(Keyframe(frame: 10, value: 10, interpolationOut: .hold))
        // Left kf is linear → linear lerp applies.
        #expect(track.sample(at: 5, fallback: 0) == 5.0)
    }
}

@Suite("Interpolation primitives")
struct InterpolationPrimitiveTests {

    @Test func smoothstepEndpointsAreZeroAndOne() {
        #expect(smoothstep(0) == 0)
        #expect(smoothstep(1) == 1)
    }

    @Test func smoothstepMidpointIsHalf() {
        // t*t*(3-2t) at t=0.5: 0.25 * 2 = 0.5.
        #expect(smoothstep(0.5) == 0.5)
    }

    @Test func smoothstepFlattensNearEdges() {
        // smoothstep slope at 0 and 1 is 0 — slower than linear near endpoints.
        #expect(smoothstep(0.1) < 0.1)
        #expect(smoothstep(0.9) > 0.9)
    }

    @Test func doubleInterpolationIsLinear() {
        #expect(Double.keyframeInterpolate(0, 10, t: 0.25) == 2.5)
        #expect(Double.keyframeInterpolate(-5, 5, t: 0.5) == 0)
    }

    @Test func animPairInterpolatesBothComponentsIndependently() {
        let result = AnimPair.keyframeInterpolate(
            AnimPair(a: 0, b: 100),
            AnimPair(a: 10, b: 200),
            t: 0.5
        )
        #expect(result.a == 5)
        #expect(result.b == 150)
    }

    @Test func cropInterpolatesAllFourInsets() {
        let result = Crop.keyframeInterpolate(
            Crop(left: 0, top: 0, right: 0, bottom: 0),
            Crop(left: 1, top: 1, right: 1, bottom: 1),
            t: 0.25
        )
        #expect(result.left == 0.25)
        #expect(result.top == 0.25)
        #expect(result.right == 0.25)
        #expect(result.bottom == 0.25)
    }
}
