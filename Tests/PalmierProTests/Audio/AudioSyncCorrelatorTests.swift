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
}
