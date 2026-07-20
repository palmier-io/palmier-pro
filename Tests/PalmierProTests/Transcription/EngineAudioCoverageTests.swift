// Coverage guard: an interrupted decode must not be cached as a complete transcript. Verifies the
// non-silent-end estimate and the shortfall rule that engines apply before returning a result.
import Foundation
import Testing
@testable import PalmierPro

@Suite("EngineAudio coverage guard")
struct EngineAudioCoverageTests {
    private func samples(speechSeconds: Double, totalSeconds: Double) -> [Float] {
        let rate = EngineAudio.sampleRate
        let speechCount = Int(speechSeconds * Double(rate))
        let total = Int(totalSeconds * Double(rate))
        return (0..<total).map { $0 < speechCount ? 0.3 : 0.0 }
    }

    private func segment(end: Double) -> [TranscriptionSegment] {
        [TranscriptionSegment(text: "x", start: 0, end: end)]
    }

    @Test func rejectsHalfLengthTranscript() {
        let gap = EngineAudio.coverageShortfall(
            segments: segment(end: 5.0), samples: samples(speechSeconds: 10, totalSeconds: 10))
        let shortfall = try? #require(gap)
        #expect(shortfall?.expected ?? 0 > 9.5)
        #expect(shortfall?.covered == 5.0)
    }

    @Test func acceptsFullLengthTranscript() {
        let gap = EngineAudio.coverageShortfall(
            segments: segment(end: 9.5), samples: samples(speechSeconds: 10, totalSeconds: 10))
        #expect(gap == nil)
    }

    @Test func trailingSilenceDoesNotFalsePositive() {
        // Speech ends at 8s, then a 2s silent tail. A transcript reaching 8s covers the speech.
        let gap = EngineAudio.coverageShortfall(
            segments: segment(end: 8.0), samples: samples(speechSeconds: 8, totalSeconds: 10))
        #expect(gap == nil)
    }

    @Test func emptyTranscriptAlwaysCovers() {
        let gap = EngineAudio.coverageShortfall(
            segments: [], samples: samples(speechSeconds: 10, totalSeconds: 10))
        #expect(gap == nil)
    }

    @Test func silentAudioIsNotJudged() {
        let gap = EngineAudio.coverageShortfall(
            segments: segment(end: 5.0), samples: samples(speechSeconds: 0, totalSeconds: 10))
        #expect(gap == nil)
    }

    @Test func nonSilentEndExcludesTrailingSilence() {
        let end = EngineAudio.nonSilentEnd(samples: samples(speechSeconds: 6, totalSeconds: 10))
        #expect(end > 5.8 && end < 6.2)
    }
}
