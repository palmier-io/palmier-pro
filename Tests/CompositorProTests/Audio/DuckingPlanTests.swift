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
        #expect(result.windows == [94 ..< 170])
        #expect(result.keyframes.map(\.frame) == [94, 104, 160, 170])
        let values = result.keyframes.map(\.value)
        #expect(abs(values[0] - 1.0) < 1e-9)
        #expect(abs(values[1] - pow(10, -12.0 / 20)) < 1e-9)
        #expect(abs(values[2] - values[1]) < 1e-9)
        #expect(abs(values[3] - 1.0) < 1e-9)
    }

    @Test func speechInsideTheMergeGapBecomesOneSpan() throws {
        let result = try plan(spans: [100 ..< 140, 145 ..< 200], parameters: .init(
            duckDb: -12, attackFrames: 6, holdFrames: 0, releaseFrames: 10, mergeGapFrames: 12
        ))
        #expect(result.windows == [94 ..< 210])
        #expect(result.keyframes.map(\.frame) == [94, 100, 200, 210])
    }

    @Test func overlappingRampsCollapseIntoOneDuckingLevel() throws {
        // A release that would reach past the next attack must not pump the bed.
        let result = try plan(spans: [100 ..< 130, 145 ..< 190], parameters: .init(
            duckDb: -12, attackFrames: 6, holdFrames: 0, releaseFrames: 40, mergeGapFrames: 0
        ))
        #expect(result.windows == [94 ..< 230])
        let frames = result.keyframes.map(\.frame)
        #expect(frames == [94, 100, 190, 230])
        #expect(result.keyframes.filter { abs($0.value - 1.0) < 1e-9 }.count == 2)
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
        #expect(result.keyframes.allSatisfy { abs($0.value - 1.0) < 1e-9 })
    }

    @Test func keyframesAreSortedAndUnique() throws {
        let result = try plan(duration: 500, spans: [50 ..< 90, 200 ..< 240, 400 ..< 460])
        let frames = result.keyframes.map(\.frame)
        #expect(frames == frames.sorted())
        #expect(Set(frames).count == frames.count)
        #expect(result.windows.count == 3)
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
