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

    @Test func containsIncludesBothEnds() {
        // Note: contains uses `<= endFrame` — the start of the next clip is "contained" too.
        let clip = Fixtures.clip(start: 50, duration: 30) // endFrame = 80
        #expect(clip.contains(timelineFrame: 50))
        #expect(clip.contains(timelineFrame: 80))
        #expect(!clip.contains(timelineFrame: 49))
        #expect(!clip.contains(timelineFrame: 81))
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
        clip.audioFadeInFrames = 10
        #expect(clip.fadeMultiplier(at: -1) == 0)
        #expect(clip.fadeMultiplier(at: 101) == 0)
    }

    @Test func linearFadeInRampsZeroToOne() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.audioFadeInFrames = 10
        clip.audioFadeInInterpolation = .linear
        #expect(clip.fadeMultiplier(at: 0) == 0)
        #expect(clip.fadeMultiplier(at: 5) == 0.5)
        #expect(clip.fadeMultiplier(at: 10) == 1.0)
        #expect(clip.fadeMultiplier(at: 50) == 1.0)
    }

    @Test func smoothFadeInUsesSmoothstep() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.audioFadeInFrames = 10
        clip.audioFadeInInterpolation = .smooth
        // smoothstep(0)=0, smoothstep(0.5)=0.5, smoothstep(1)=1.
        #expect(clip.fadeMultiplier(at: 0) == 0)
        #expect(clip.fadeMultiplier(at: 5) == 0.5)
        #expect(clip.fadeMultiplier(at: 10) == 1.0)
    }

    @Test func combinedFadesTakeMinimumOfInAndOut() {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.audioFadeInFrames = 20
        clip.audioFadeOutFrames = 20
        clip.audioFadeInInterpolation = .linear
        clip.audioFadeOutInterpolation = .linear
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
        clip.audioFadeInFrames = 10
        clip.audioFadeInInterpolation = .linear
        // fade at frame 5 = 0.5; static volume = 0.5 → 0.25.
        #expect(abs(clip.volumeAt(frame: 5) - 0.25) < 1e-9)
    }
}
