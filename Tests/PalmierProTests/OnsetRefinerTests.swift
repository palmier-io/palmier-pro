import Foundation
import Testing
@testable import PalmierPro

@Suite("OnsetRefiner")
struct OnsetRefinerTests {
    private let sampleRate = 16_000
    private let fps = 30

    /// 1s of silence followed by `toneSeconds` of a 440Hz burst — onset at exactly 1.0s.
    private func silenceThenTone(toneSeconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: sampleRate)
        let toneCount = Int(toneSeconds * Double(sampleRate))
        for n in 0..<toneCount {
            samples.append(0.3 * sinf(2 * .pi * 440 * Float(n) / Float(sampleRate)))
        }
        return samples
    }

    private func refine(_ words: [TranscriptionWord], _ samples: [Float]) -> [TranscriptionWord] {
        OnsetRefiner.refine(words: words, samples: samples, sampleRate: sampleRate, fps: fps)
    }

    @Test func rollsBoundaryQuantizedStartBackToOnset() {
        let samples = silenceThenTone(toneSeconds: 0.6)
        let word = TranscriptionWord(text: "hi", start: 1.4, end: 1.9, aligned: true)
        let refined = refine([word], samples)[0]

        #expect(refined.start! < 1.4, "start should roll earlier toward the onset")
        #expect(refined.start! <= 1.0, "should land at or before the onset (biased early, never late)")
        #expect(abs(refined.start! - 1.0) <= 3.0 / Double(fps), "within 3 frames of the true onset")
        #expect(refined.end == 1.9, "end is untouched")
        #expect(refined.aligned == true, "acoustically anchored word keeps aligned: true")
    }

    @Test func neverRollsBeforePreviousWordEnd() {
        let samples = silenceThenTone(toneSeconds: 0.6)
        let words = [
            TranscriptionWord(text: "a", start: 0.1, end: 0.96, aligned: true),
            TranscriptionWord(text: "b", start: 1.4, end: 1.9, aligned: true),
        ]
        let refined = refine(words, samples)

        #expect(refined[1].start! < 1.4, "second word rolls earlier")
        #expect(refined[1].start! >= 0.96, "but never before the previous word's end")
    }

    @Test func rollbackIsCapped() {
        let samples = silenceThenTone(toneSeconds: 0.6)
        let word = TranscriptionWord(text: "late", start: 2.8, end: 3.2, aligned: true)
        let refined = refine([word], samples)[0]

        #expect(refined.start! >= 2.8 - OnsetRefiner.maxRollback, "rollback is bounded to the cap")
    }

    @Test func rollbackReachesOnsetBeyondOldCap() {
        // Silence 0–1s, tone 1.0–1.6s, then silence to 3.6s. A word quantized to 2.9 sits 1.9s past the
        // onset — beyond the former 1.5s cap. The raised cap lets it roll to the true onset (~1.0s).
        var samples = [Float](repeating: 0, count: sampleRate)
        for n in 0..<Int(0.6 * Double(sampleRate)) {
            samples.append(0.3 * sinf(2 * .pi * 440 * Float(n) / Float(sampleRate)))
        }
        samples.append(contentsOf: [Float](repeating: 0, count: 2 * sampleRate))
        let word = TranscriptionWord(text: "late", start: 2.9, end: 3.3, aligned: true)
        let refined = refine([word], samples)[0]

        #expect(refined.start! < 2.9 - 1.5, "rolls back further than the old 1.5s cap")
        #expect(abs(refined.start! - 1.0) <= 3.0 / Double(fps), "lands at the true onset ~1.0s")
    }

    @Test func leavesInterpolatedFlagUnchanged() {
        let samples = silenceThenTone(toneSeconds: 0.6)
        let word = TranscriptionWord(text: "hi", start: 1.4, end: 1.9, aligned: false)
        let refined = refine([word], samples)[0]

        #expect(refined.aligned == false, "interpolated timing is never upgraded to aligned")
    }

    @Test func leavesInGapWordsUntouched() {
        let samples = silenceThenTone(toneSeconds: 0.6)
        let words = [
            TranscriptionWord(text: "one", start: 1.05, end: 1.2, aligned: true),
            TranscriptionWord(text: "two", start: 1.25, end: 1.4, aligned: true),  // 50ms gap < 300ms
        ]
        let refined = refine(words, samples)

        #expect(refined[1].start == 1.25, "a word without a real pause before it is not refined")
    }
}
