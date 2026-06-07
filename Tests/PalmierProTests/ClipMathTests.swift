import Testing
@testable import PalmierPro

@Suite("Clip math")
struct ClipMathTests {

    // MARK: - endFrame / source-frame math

    @Test func endFrameIsStartPlusDuration() {
        let clip = Fixtures.clip(start: 100, duration: 50)
        #expect(clip.endFrame == 150)
    }

    @Test func sourceFramesConsumedScalesByspeed() {
        // duration=100 timeline frames × speed=2.0 → 200 source frames consumed.
        let clip = Fixtures.clip(start: 0, duration: 100, speed: 2.0)
        #expect(clip.sourceFramesConsumed == 200)
    }

    @Test func sourceFramesConsumedRoundsForFractionalSpeed() {
        // 33 * 0.75 = 24.75 → rounds to 25.
        let clip = Fixtures.clip(start: 0, duration: 33, speed: 0.75)
        #expect(clip.sourceFramesConsumed == 25)
    }

    @Test func sourceDurationIncludesBothTrims() {
        // consumed (100) + trimStart (10) + trimEnd (5) = 115.
        let clip = Fixtures.clip(start: 0, duration: 100, trimStart: 10, trimEnd: 5)
        #expect(clip.sourceDurationFrames == 115)
    }

    // MARK: - contains(timelineFrame:)

    @Test func containsIsHalfOpen() {
        // Half-open interval [startFrame, endFrame). endFrame belongs to whatever comes next,
        // matching the convention used by OverwriteEngine and RippleEngine.
        let clip = Fixtures.clip(start: 50, duration: 30) // endFrame = 80
        #expect(clip.contains(timelineFrame: 50))   // start is in
        #expect(clip.contains(timelineFrame: 79))   // last visible frame is in
        #expect(!clip.contains(timelineFrame: 80))  // endFrame is NOT in
        #expect(!clip.contains(timelineFrame: 49))
    }

    // MARK: - timelineFrame(sourceSeconds:fps:)

    @Test func timelineFrameMapsSourceSecondsThroughTrim() {
        // start=100, trimStart=30 source frames, speed=1, fps=30.
        // sourceSeconds=2.0 → 60 source frames → offsetFromTrim=30 → timeline = 100+30 = 130.
        let clip = Fixtures.clip(start: 100, duration: 60, trimStart: 30)
        #expect(clip.timelineFrame(sourceSeconds: 2.0, fps: 30) == 130)
    }

    @Test func timelineFrameDividesByspeed() {
        // start=0, speed=2.0, fps=30. sourceSeconds=2.0 → 60 source frames → 60/2 = 30 timeline frames.
        let clip = Fixtures.clip(start: 0, duration: 100, speed: 2.0)
        #expect(clip.timelineFrame(sourceSeconds: 2.0, fps: 30) == 30)
    }

    @Test func timelineFrameBeforeTrimReturnsNil() {
        // sourceSeconds=0.5 → 15 source frames; trimStart=30 → offsetFromTrim < 0 → nil.
        let clip = Fixtures.clip(start: 100, duration: 60, trimStart: 30)
        #expect(clip.timelineFrame(sourceSeconds: 0.5, fps: 30) == nil)
    }

    @Test func timelineFrameAtOrPastEndFrameReturnsNil() {
        // Note: the guard here is `< endFrame` (exclusive), unlike contains() which uses `<=`.
        // start=0, duration=30, speed=1, fps=30. sourceSeconds=1.0 → frame=30, but 30 < 30 is false → nil.
        let clip = Fixtures.clip(start: 0, duration: 30)
        #expect(clip.timelineFrame(sourceSeconds: 1.0, fps: 30) == nil)
        #expect(clip.timelineFrame(sourceSeconds: 2.0, fps: 30) == nil)
    }

    // MARK: - fadeMultiplier

    @Test func fadeMultiplierIsOneEverywhereWithNoFades() {
        let clip = Fixtures.clip(start: 0, duration: 100)
        #expect(clip.fadeMultiplier(at: 0) == 1.0)
        #expect(clip.fadeMultiplier(at: 50) == 1.0)
        #expect(clip.fadeMultiplier(at: 100) == 1.0)
    }

    @Test func fadeMultiplierIsZeroOutsideClipRange() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.fadeInFrames = 10
        #expect(clip.fadeMultiplier(at: -1) == 0)
        #expect(clip.fadeMultiplier(at: 101) == 0)
    }

    @Test func linearFadeInRampsZeroToOne() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.fadeInFrames = 10
        clip.fadeInInterpolation = .linear
        #expect(clip.fadeMultiplier(at: 0) == 0)
        #expect(clip.fadeMultiplier(at: 5) == 0.5)
        #expect(clip.fadeMultiplier(at: 10) == 1.0)
        #expect(clip.fadeMultiplier(at: 50) == 1.0)
    }

    @Test func smoothFadeInUsesSmoothstep() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.fadeInFrames = 10
        clip.fadeInInterpolation = .smooth
        // smoothstep(0)=0, smoothstep(0.5)=0.5, smoothstep(1)=1.
        #expect(clip.fadeMultiplier(at: 0) == 0)
        #expect(clip.fadeMultiplier(at: 5) == 0.5)
        #expect(clip.fadeMultiplier(at: 10) == 1.0)
    }

    @Test func combinedFadesTakeMinimumOfInAndOut() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.fadeInFrames = 20
        clip.fadeOutFrames = 20
        clip.fadeInInterpolation = .linear
        clip.fadeOutInterpolation = .linear
        // Start: fadeIn=0, fadeOut=1 → min=0.
        #expect(clip.fadeMultiplier(at: 0) == 0)
        // End: fadeIn=1, fadeOut=0 → min=0.
        #expect(clip.fadeMultiplier(at: 100) == 0)
        // Middle: both ramps fully up.
        #expect(clip.fadeMultiplier(at: 50) == 1.0)
    }

    // MARK: - volumeAt

    @Test func volumeAtReturnsStaticVolumeWithoutFadeOrKfs() {
        let clip = Fixtures.clip(start: 0, duration: 100, volume: 0.5)
        #expect(clip.volumeAt(frame: 50) == 0.5)
    }

    @Test func volumeAtMultipliesStaticVolumeByFade() {
        var clip = Fixtures.clip(start: 0, duration: 100, volume: 0.5)
        clip.fadeInFrames = 10
        clip.fadeInInterpolation = .linear
        // fade at frame 5 = 0.5; static volume = 0.5 → 0.25.
        #expect(abs(clip.volumeAt(frame: 5) - 0.25) < 1e-9)
    }

    // MARK: - opacityAt + rawOpacityAt

    @Test func opacityAtReturnsStaticOpacityWithoutFade() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.opacity = 0.5
        #expect(clip.opacityAt(frame: 50) == 0.5)
    }

    @Test func opacityAtMultipliesStaticOpacityByFade() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.opacity = 0.5
        clip.fadeInFrames = 10
        clip.fadeInInterpolation = .linear
        // base 0.5 × linear fade at frame 5 (0.5) = 0.25.
        #expect(abs(clip.opacityAt(frame: 5) - 0.25) < 1e-9)
    }

    @Test func opacityAtMultipliesKeyframedOpacityByFade() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.opacity = 1.0
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.4),
            Keyframe(frame: 100, value: 0.4)
        ])
        clip.fadeOutFrames = 20
        clip.fadeOutInterpolation = .linear
        // At frame 90: keyframed opacity = 0.4, fadeOut multiplier = 0.5 → 0.2.
        #expect(abs(clip.opacityAt(frame: 90) - 0.2) < 1e-9)
    }

    @Test func opacityAtIgnoresFadeForAudioClips() {
        // Audio clips share the same fade fields as visual clips, but fades modulate volume
        // there — opacity should stay at the authored value.
        var clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 100)
        clip.opacity = 1.0
        clip.fadeInFrames = 10
        clip.fadeInInterpolation = .linear
        #expect(clip.opacityAt(frame: 5) == 1.0)
    }

    @Test func rawOpacityAtIgnoresFade() {
        // Round-trip guard for the inspector / stampKeyframe path: rawOpacityAt must
        // return the authored value even when a fade would zero it visually.
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.opacity = 1.0
        clip.fadeInFrames = 10
        clip.fadeInInterpolation = .linear
        #expect(clip.rawOpacityAt(frame: 0) == 1.0)
        #expect(clip.rawOpacityAt(frame: 5) == 1.0)
        #expect(clip.opacityAt(frame: 5) == 0.5)
    }

    // MARK: - clampFadesToDuration / setFade

    @Test func clampClipsFadesToDuration() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.fadeInFrames = 80
        clip.fadeOutFrames = 80
        clip.clampFadesToDuration()
        // fadeOut clamps to remainder after fadeIn: 100 - 80 = 20.
        #expect(clip.fadeInFrames == 80)
        #expect(clip.fadeOutFrames == 20)
    }

    @Test func setFadeWritesEdgeFields() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.setFade(.left, frames: 25)
        clip.setFade(.right, frames: 30)
        #expect(clip.fadeInFrames == 25)
        #expect(clip.fadeOutFrames == 30)
    }

    @Test func setDurationClampsAllKeyframeTracks() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 90, value: 0.5)])
        clip.positionTrack = KeyframeTrack(keyframes: [Keyframe(frame: 90, value: AnimPair(a: 0.1, b: 0.2))])
        clip.scaleTrack = KeyframeTrack(keyframes: [Keyframe(frame: 90, value: AnimPair(a: 0.5, b: 0.5))])
        clip.rotationTrack = KeyframeTrack(keyframes: [Keyframe(frame: 90, value: 15)])
        clip.cropTrack = KeyframeTrack(keyframes: [Keyframe(frame: 90, value: Crop(left: 0.1, top: 0, right: 0, bottom: 0))])
        clip.volumeTrack = KeyframeTrack(keyframes: [Keyframe(frame: 90, value: -6)])

        clip.setDuration(30)

        #expect(clip.opacityTrack == nil)
        #expect(clip.positionTrack == nil)
        #expect(clip.scaleTrack == nil)
        #expect(clip.rotationTrack == nil)
        #expect(clip.cropTrack == nil)
        #expect(clip.volumeTrack == nil)
    }
}

// MARK: - Adversarial

@Suite("Clip math — adversarial")
struct ClipMathAdversarialTests {

    /// Cross-API consistency probe — currently FAILS.
    /// Clip.contains uses `<= endFrame` (inclusive), Clip.timelineFrame uses `< endFrame`
    /// (exclusive). The `.disabled` flag test below encodes the proposed resolution.
    @Test func clipContainsAndTimelineFrameAgreeAtEndFrame() {
        let clip = Fixtures.clip(start: 0, duration: 30)
        let containsEnd = clip.contains(timelineFrame: 30)
        let mappedEnd = clip.timelineFrame(sourceSeconds: 1.0, fps: 30)
        if containsEnd {
            #expect(mappedEnd == 30, "contains says endFrame is inside but timelineFrame won't map to it")
        } else {
            #expect(mappedEnd == nil)
        }
    }

    /// Resolved: endFrame is exclusive. This test pins the decision so the boundary
    /// convention can't drift back without a test failure.
    @Test func endFrameIsExclusive() {
        let clip = Fixtures.clip(start: 0, duration: 30)
        #expect(clip.contains(timelineFrame: 30) == false)
    }

    // MARK: - Edge inputs

    @Test func zeroDurationClipDoesNotCrashFadeMultiplier() {
        var clip = Fixtures.clip(start: 0, duration: 0)
        clip.fadeInFrames = 5
        clip.fadeInInterpolation = .linear
        _ = clip.fadeMultiplier(at: 0)
        _ = clip.fadeMultiplier(at: -1)
        _ = clip.fadeMultiplier(at: 1)
    }

    @Test func zeroSpeedDoesNotDivideByZeroInTimelineFrame() {
        // The implementation guards with `max(speed, 0.0001)` — verify no crash.
        let clip = Fixtures.clip(start: 0, duration: 100, speed: 0)
        _ = clip.timelineFrame(sourceSeconds: 1.0, fps: 30)
    }

    @Test func negativeStartFrameProducesNegativeEndFrame() {
        let clip = Fixtures.clip(start: -50, duration: 30)
        #expect(clip.endFrame == -20)
        #expect(clip.contains(timelineFrame: -40))
        #expect(!clip.contains(timelineFrame: 0))
    }
}

@Suite("Timeline — invariants")
struct TimelineInvariantTests {

    @Test func timelineTotalFramesEqualsMaximumTrackEndFrame() {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 50)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(start: 100, duration: 80)]),
        ])
        let manualMax = timeline.tracks.map(\.endFrame).max() ?? 0
        #expect(timeline.totalFrames == manualMax)
    }

    @Test func emptyTimelineHasZeroTotalFrames() {
        let timeline = Fixtures.timeline(tracks: [])
        #expect(timeline.totalFrames == 0)
    }
}
