import Foundation
import Testing
@testable import CompositorPro

@Suite("DuckingPlan")
struct DuckingPlanTests {
    private func plan(
        bedStart: Int = 0,
        duration: Int = 300,
        spans: [Range<Int>],
        parameters: DuckingPlan.Parameters = .default
    ) throws -> DuckingPlan {
        try DuckingPlan.plan(
            bedStartFrame: bedStart,
            bedDurationFrames: duration,
            speechSpans: spans,
            parameters: parameters
        )
    }

    @Test func singleSpanDucksAfterAttackAndReleasesAfterHold() throws {
        let result = try plan(spans: [100 ..< 160], parameters: .init(
            duckDb: -12, attackFrames: 6, holdFrames: 4, releaseFrames: 10, mergeGapFrames: 12
        ))
        #expect(result.windows == [94 ..< 174])
        #expect(result.keyframes.map(\.frame) == [0, 94, 100, 164, 174])
        let values = result.keyframes.map(\.value)
        #expect(values == [0, 0, -12, -12, 0])
    }

    @Test func speechInsideTheMergeGapBecomesOneSpan() throws {
        let result = try plan(spans: [100 ..< 140, 145 ..< 200], parameters: .init(
            duckDb: -12, attackFrames: 6, holdFrames: 0, releaseFrames: 10, mergeGapFrames: 12
        ))
        #expect(result.windows == [94 ..< 210])
        #expect(result.keyframes.map(\.frame) == [0, 94, 100, 200, 210])
    }

    @Test func overlappingRampsCollapseIntoOneDuckingLevel() throws {
        // A release that would reach past the next attack must not pump the bed.
        let result = try plan(spans: [100 ..< 130, 145 ..< 190], parameters: .init(
            duckDb: -12, attackFrames: 6, holdFrames: 0, releaseFrames: 40, mergeGapFrames: 0
        ))
        #expect(result.windows == [94 ..< 230])
        let frames = result.keyframes.map(\.frame)
        #expect(frames == [0, 94, 100, 190, 230])
        #expect(result.keyframes.filter { $0.value < 0 }.map(\.frame) == [100, 190])
    }

    @Test func rampsClampToTheBedBounds() throws {
        let result = try plan(bedStart: 50, duration: 100, spans: [40 ..< 90], parameters: .init(
            duckDb: -6, attackFrames: 20, holdFrames: 0, releaseFrames: 30, mergeGapFrames: 0
        ))
        #expect(result.windows == [50 ..< 120])
        // No room for an attack, so the bed is already down when the span starts.
        #expect(result.keyframes.map(\.frame) == [0, 40, 70])
    }

    @Test func spansOutsideTheBedAreIgnoredNotClamped() throws {
        let result = try plan(bedStart: 100, duration: 50, spans: [0 ..< 40, 120 ..< 160, 200 ..< 260])
        #expect(result.ignoredSpans == 2)
        #expect(result.windows == [114 ..< 150])
    }

    @Test func noSpeechYieldsNoKeyframes() throws {
        let result = try plan(spans: [])
        #expect(result.isEmpty)
        #expect(result.windows.isEmpty)
    }

    @Test(arguments: [Double.infinity, -.infinity])
    func nonFiniteDecibelsAreRejected(db: Double) {
        #expect(throws: DuckingPlan.Failure.nonFiniteDecibels(db)) {
            try DuckingPlan.plan(
                bedStartFrame: 0, bedDurationFrames: 100,
                speechSpans: [10 ..< 20],
                parameters: .init(duckDb: db)
            )
        }
    }

    @Test func notANumberDecibelsAreRejected() {
        // NaN is never equal to itself, so match the type rather than the value.
        #expect(throws: DuckingPlan.Failure.self) {
            try DuckingPlan.plan(
                bedStartFrame: 0, bedDurationFrames: 100,
                speechSpans: [10 ..< 20],
                parameters: .init(duckDb: .nan)
            )
        }
    }

    @Test func negativeFrameCountsAreRejected() {
        #expect(throws: DuckingPlan.Failure.negativeFrames("attackFrames, holdFrames, releaseFrames and mergeGapFrames")) {
            try DuckingPlan.plan(
                bedStartFrame: 0, bedDurationFrames: 100,
                speechSpans: [10 ..< 20],
                parameters: .init(attackFrames: -1)
            )
        }
    }

    @Test func anEmptyBedIsRejected() {
        #expect(throws: DuckingPlan.Failure.emptyClip) {
            try DuckingPlan.plan(bedStartFrame: 0, bedDurationFrames: 0, speechSpans: [])
        }
    }

    @Test func zeroDecibelsProducesAnEnvelopeThatChangesNothing() throws {
        let result = try plan(spans: [100 ..< 160], parameters: .init(duckDb: 0))
        #expect(result.isEmpty)
    }

    @Test func keyframesAreSortedAndUnique() throws {
        let result = try plan(duration: 500, spans: [50 ..< 90, 200 ..< 240, 400 ..< 460])
        let frames = result.keyframes.map(\.frame)
        #expect(frames == frames.sorted())
        #expect(Set(frames).count == frames.count)
        #expect(result.windows.count == 3)
    }

    @Test func duckingAttenuatesThroughTheClipVolumeContract() throws {
        let result = try plan(spans: [100 ..< 160])
        var clip = Clip(mediaRef: "bed", mediaType: .audio, startFrame: 30, durationFrames: 300)
        clip.volumeTrack = KeyframeTrack(keyframes: result.keyframes)
        #expect(abs(clip.rawVolumeAt(frame: 150) - pow(10, -12.0 / 20)) < 1e-9)
        #expect(clip.rawVolumeAt(frame: 60) == 1)
        #expect(clip.rawVolumeAt(frame: 250) == 1)
    }

    @Test func zeroAttackDoesNotDuckBeforeSpeech() throws {
        let result = try plan(spans: [100 ..< 160], parameters: .init(attackFrames: 0))
        let track = KeyframeTrack(keyframes: result.keyframes)
        #expect(track.sample(at: 99, fallback: 0) == 0)
        #expect(track.sample(at: 100, fallback: 0) == -12)
    }

    @Test func speechAtTheTailDoesNotRestoreGainDuringSpeech() throws {
        let result = try plan(duration: 160, spans: [100 ..< 160])
        let track = KeyframeTrack(keyframes: result.keyframes)
        #expect(track.sample(at: 159, fallback: 0) == -12)
        #expect(result.keyframes.allSatisfy { $0.frame < 160 })
    }

    @Test func overflowingBedRangeIsRefused() {
        #expect(throws: DuckingPlan.Failure.self) {
            try plan(bedStart: Int.max - 1, duration: 3, spans: [])
        }
    }

    @Test func largeEnvelopeDurationsClampWithoutOverflow() throws {
        let result = try plan(spans: [100 ..< 160], parameters: .init(
            attackFrames: Int.max, holdFrames: Int.max, releaseFrames: Int.max, mergeGapFrames: Int.max))
        #expect(result.windows == [0 ..< 300])
        #expect(result.keyframes.allSatisfy { (0..<300).contains($0.frame) })
    }
}

@Suite("AudioFadeCurve")
struct AudioFadeCurveTests {
    @Test func equalPowerCurveCrossesSmoothlyFromOutgoingToIncoming() {
        let samples = AudioFadeCurve.equalPowerSamples(frames: 96)
        #expect(abs(samples.first!.outgoing - 1) < 1e-9)
        #expect(abs(samples.first!.incoming) < 1e-9)
        #expect(abs(samples.last!.outgoing) < 1e-9)
        #expect(abs(samples.last!.incoming - 1) < 1e-9)
        #expect(samples.map(\.frameOffset) == samples.map(\.frameOffset).sorted())
        #expect(samples.last!.frameOffset == 96)
    }

    @Test func equalPowerKeepsSumOfSquaresNearUnity() {
        for sample in AudioFadeCurve.equalPowerSamples(frames: 96) {
            // A linear crossfade dips ~3 dB here; equal power holds this near 1.
            #expect(abs(sample.outgoing * sample.outgoing + sample.incoming * sample.incoming - 1) < 1e-6)
        }
    }

    @Test func equalPowerHandlesAZeroLengthRamp() {
        #expect(AudioFadeCurve.equalPowerSamples(frames: 0).isEmpty)
    }
}
