import Foundation
import Testing
@testable import PalmierPro

@Suite("AudioSyncCorrelator")
struct AudioSyncCorrelatorTests {

    private func signal(count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> [Float] {
        var state = seed
        var out: [Float] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let bits = (state >> 33)
            out.append(Float(bits % 1000) / 1000.0)
        }
        return out
    }

    @Test func detectsZeroLagOnIdenticalSignals() {
        let s = signal(count: 500)
        let result = AudioSyncCorrelator.correlate(reference: s, target: s, maxLagHops: 50)
        let r = try! #require(result)
        #expect(r.lagHops == 0)
        #expect(r.confidence > 0.99)
    }

    @Test func detectsPositiveLag() {
        let base = signal(count: 600)
        let lag = 20
        let reference = base
        let target = Array(base[lag...])
        let result = AudioSyncCorrelator.correlate(reference: reference, target: target, maxLagHops: 100)
        let r = try! #require(result)
        #expect(r.lagHops == lag)
        #expect(r.confidence > 0.99)
    }

    @Test func detectsNegativeLag() {
        let base = signal(count: 600)
        let lag = 15
        let reference = Array(base[lag...])
        let target = base
        let result = AudioSyncCorrelator.correlate(reference: reference, target: target, maxLagHops: 100)
        let r = try! #require(result)
        #expect(r.lagHops == -lag)
        #expect(r.confidence > 0.99)
    }

    @Test func isInvariantToGain() {
        let base = signal(count: 400)
        let lag = 10
        let reference = base
        let target = base[lag...].map { $0 * 0.25 + 0.05 }
        let result = AudioSyncCorrelator.correlate(reference: reference, target: Array(target), maxLagHops: 60)
        let r = try! #require(result)
        #expect(r.lagHops == lag)
        #expect(r.confidence > 0.95)
    }

    @Test func lowConfidenceOnUncorrelatedSignals() {
        let reference = signal(count: 500, seed: 1)
        let target = signal(count: 500, seed: 999)
        let result = AudioSyncCorrelator.correlate(reference: reference, target: target, maxLagHops: 50)
        let r = try! #require(result)
        #expect(r.confidence < 0.5)
    }

    @Test func returnsNilWhenOverlapTooSmall() {
        let reference = signal(count: 8)
        let target = signal(count: 8)
        #expect(AudioSyncCorrelator.correlate(reference: reference, target: target, maxLagHops: 0) == nil)
    }

    @Test func handlesEmptyInput() {
        #expect(AudioSyncCorrelator.correlate(reference: [], target: [1, 2, 3], maxLagHops: 5) == nil)
        #expect(AudioSyncCorrelator.correlate(reference: [1, 2, 3], target: [], maxLagHops: 5) == nil)
    }

    @Test func seededCorrelationChoosesStrongerFullWindowMatch() async {
        let target = signal(count: 300, seed: 7)
        let interference = signal(count: 300, seed: 99)
        var reference = [Float](repeating: 0, count: 1_000)
        reference.replaceSubrange(100..<400, with: target)
        reference.replaceSubrange(600..<900, with: zip(target, interference).map { $0 * 0.6 + $1 * 0.4 })

        let result = await AudioSyncCorrelator.seededCorrelate(
            reference: reference, target: target, seedHops: 600, seedWindowHops: 10,
            maxLagHops: 200, minOverlapHops: 100, minConfidence: 0.5
        )

        #expect(result?.lagHops == 100)
        #expect((result?.confidence ?? 0) > 0.99)
    }

    @Test func seededCorrelateObservesCallingTaskCancellation() async {
        let s = signal(count: 2_000)
        let result = await Task { () -> AudioSyncCorrelator.Result? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await AudioSyncCorrelator.seededCorrelate(
                reference: s, target: s, seedHops: nil, seedWindowHops: 10,
                maxLagHops: 500, minOverlapHops: 100, minConfidence: 0.5
            )
        }.value
        #expect(result == nil)
    }

    @Test func edgePeakInRefinedRangeIsNotSuppressedByNeighboringRange() {
        let omega = 2.0 * Double.pi / 64.0
        let reference = (0..<256).map { Float(sin(Double($0) * omega)) }
        let target = (0..<200).map { Float(sin(Double($0 + 10) * omega)) }
        let candidates = AudioSyncCorrelator.exactCandidates(
            reference: reference, target: target,
            lagRanges: [0...2, 9...11], minOverlapHops: 16
        )
        #expect(candidates.first?.lagHops == 10)
        #expect(candidates.contains { $0.lagHops == 2 })
    }

    @Test func requestedOverlapAdaptsForShortClips() {
        let samples = signal(count: 120)
        let result = AudioSyncCorrelator.correlate(
            reference: samples, target: samples, maxLagHops: 20, minOverlapHops: 300
        )

        #expect(result?.lagHops == 0)
        #expect((result?.confidence ?? 0) > 0.99)
    }

    @Test func multiresolutionSearchRefinesToExactHop() {
        let base = signal(count: 2_000)
        let lag = 37
        let result = AudioSyncCorrelator.correlate(
            reference: base, target: Array(base[lag...]), maxLagHops: 400, minOverlapHops: 300
        )

        #expect(result?.lagHops == lag)
        #expect((result?.confidence ?? 0) > 0.99)
    }

    @Test func pyramidSearchFindsLargeNonalignedLag() {
        let base = signal(count: 25_000)
        let lag = 20_003
        let target = Array(base[lag..<(lag + 4_000)])
        let result = AudioSyncCorrelator.correlate(
            reference: base, target: target, maxLagHops: 24_000, minOverlapHops: 1_000
        )

        #expect(result?.lagHops == lag)
        #expect((result?.confidence ?? 0) > 0.99)
    }

    @Test func pyramidSearchRefinesCompetingCoarsePeaks() {
        let target = signal(count: 512, seed: 73)
        let coarseAlias = Swift.stride(from: 0, to: target.count, by: 2).flatMap {
            target[$0..<min($0 + 2, target.count)].reversed()
        }
        var reference = [Float](repeating: 0, count: 6_000)
        reference.replaceSubrange(800..<1_312, with: coarseAlias)
        reference.replaceSubrange(5_000..<5_512, with: target)

        let result = AudioSyncCorrelator.correlate(
            reference: reference, target: target, maxLagHops: 5_500, minOverlapHops: 256
        )

        #expect(result?.lagHops == 5_000)
        #expect((result?.confidence ?? 0) > 0.99)
    }

    @Test func consensusFitsClockDriftAcrossLongRecordings() async {
        let drift = 0.0003
        let noise = signal(count: 121_000, seed: 5)
        var reference = [Float](repeating: 0, count: noise.count)
        var running: Float = 0
        for i in noise.indices {
            running += (noise[i] - running) * 0.05
            reference[i] = running
        }
        let smooth = { (x: Double) -> Float in
            let i = Int(x)
            guard i + 1 < reference.count else { return reference[min(i, reference.count - 1)] }
            let frac = Float(x - Double(i))
            return reference[i] * (1 - frac) + reference[i + 1] * frac
        }
        let head = 400.0
        let target = (0..<110_000).map { smooth(head + Double($0) * (1 + drift)) }

        let result = await AudioSyncCorrelator.seededCorrelate(
            reference: reference, target: target, seedHops: nil, seedWindowHops: 10,
            maxLagHops: 120_000, minOverlapHops: 1_200, minConfidence: 0.5
        )

        let r = try! #require(result)
        #expect(abs(r.lagHops - Int(head)) <= 8)
        #expect(abs(r.driftRatio - drift) < 0.00005)
        #expect(r.confidence > 0.8)
    }

    @Test func consensusReportsZeroDriftForCleanCopies() async {
        let reference = signal(count: 120_000, seed: 9)
        let target = Array(reference[500..<110_500])

        let result = await AudioSyncCorrelator.seededCorrelate(
            reference: reference, target: target, seedHops: nil, seedWindowHops: 10,
            maxLagHops: 120_000, minOverlapHops: 1_200, minConfidence: 0.5
        )

        let r = try! #require(result)
        #expect(r.lagHops == 500)
        #expect(r.driftRatio == 0)
        #expect(r.confidence > 0.99)
    }
}
