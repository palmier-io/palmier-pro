import Foundation
import Testing
@testable import PalmierPro

@Suite("CaptionBuilder")
struct CaptionBuilderTests {
    private func segment(_ text: String, _ start: Double, _ end: Double) -> TranscriptionSegment {
        TranscriptionSegment(text: text, start: start, end: end)
    }

    @Test func keepsSegmentWholeWhenItFits() {
        let phrases = CaptionBuilder.phrases(for: segment("Hello there", 1.0, 2.0), fits: { _ in true }, minDuration: 0)
        #expect(phrases == [CaptionBuilder.Phrase(text: "Hello there", start: 1.0, end: 2.0)])
    }

    @Test func splitsAtSentenceBoundary() {
        let phrases = CaptionBuilder.phrases(for: segment("One. Two.", 0, 8), fits: { $0.count <= 5 }, minDuration: 0)
        #expect(phrases.map(\.text) == ["One.", "Two."])
        #expect(phrases.map(\.start) == [0.0, 4.0])
        #expect(phrases.map(\.end) == [4.0, 8.0])
    }

    @Test func splitsAtClauseWhenNoSentence() {
        let phrases = CaptionBuilder.phrases(for: segment("alpha, beta", 0, 2), fits: { $0.count <= 6 }, minDuration: 0)
        #expect(phrases.map(\.text) == ["alpha,", "beta"])
    }

    @Test func splitsAtMidWordWhenNoPunctuation() {
        let phrases = CaptionBuilder.phrases(for: segment("a b c d", 0, 4), fits: { $0.count <= 3 }, minDuration: 0)
        #expect(phrases.map(\.text) == ["a b", "c d"])
    }

    @Test func keepsPunctuatedTokensIntact() {
        let phrases = CaptionBuilder.phrases(for: segment("U.S. army here", 0, 6), fits: { $0.count <= 6 }, minDuration: 0)
        #expect(phrases.map(\.text) == ["U.S.", "army", "here"])
    }

    @Test func distributesTimeByCharacterCount() {
        let phrases = CaptionBuilder.phrases(for: segment("aaaa bb", 0, 6), fits: { $0.count <= 4 }, minDuration: 0)
        #expect(phrases.map(\.text) == ["aaaa", "bb"])
        #expect(phrases.map(\.start) == [0.0, 4.0])
        #expect(phrases.map(\.end) == [4.0, 6.0])
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionWord {
        TranscriptionWord(text: text, start: start, end: end)
    }

    @Test func timesPhrasesFromWordTimestamps() {
        // "aaaa" fast (0–1s), "bb" slow (1–6s): char distribution would mis-time these.
        let words = [word("aaaa", 0, 1), word("bb", 1, 6)]
        let phrases = CaptionBuilder.phrases(
            for: segment("aaaa bb", 0, 6), words: words, fits: { $0.count <= 4 }, minDuration: 0
        )
        #expect(phrases.map(\.start) == [0.0, 1.0])
        #expect(phrases.map(\.end) == [1.0, 6.0])
    }

    @Test func alignsWhenContractionSplitsIntoTwoRuns() {
        // "can't" arrives as two timed runs; "go" must still get its own run.
        let words = [word("I", 0, 0.2), word("can", 0.4, 0.6), word("'t", 0.6, 0.7), word("go", 1.0, 1.3)]
        let phrases = CaptionBuilder.phrases(
            for: segment("I can't go", 0, 1.3), words: words, fits: { $0.count <= 5 }, minDuration: 0
        )
        #expect(phrases.map(\.text) == ["I", "can't", "go"])
        #expect(phrases.map(\.start) == [0.0, 0.4, 1.0])
        #expect(phrases.map(\.end) == [0.2, 0.7, 1.3])
    }

    @Test func ignoresPunctuationOnlyTimedRuns() {
        // Periods carry timing; "Stop." must not inherit the first period's run.
        let words = [word("Wait", 0, 0.4), word(".", 0.4, 0.5), word("Stop", 1.2, 1.6), word(".", 1.6, 1.7)]
        let phrases = CaptionBuilder.phrases(
            for: segment("Wait. Stop.", 0, 1.7), words: words, fits: { $0.count <= 5 }, minDuration: 0
        )
        #expect(phrases.map(\.text) == ["Wait.", "Stop."])
        #expect(phrases.map(\.start) == [0.0, 1.2])
        #expect(phrases.map(\.end) == [0.4, 1.6])
    }

    @Test func alignsWhenNumberSplitsAcrossRuns() {
        let words = [word("costs", 0, 0.5), word("3", 0.8, 0.9), word("5", 0.9, 1.0), word("million", 1.4, 2.0)]
        let phrases = CaptionBuilder.phrases(
            for: segment("costs 3.5 million", 0, 2.0), words: words, fits: { $0.count <= 8 }, minDuration: 0
        )
        #expect(phrases.map(\.text) == ["costs", "3.5", "million"])
        #expect(phrases.map(\.start) == [0.0, 0.8, 1.4])
        #expect(phrases.map(\.end) == [0.5, 1.0, 2.0])
    }

    @Test func alignsWhenOneRunSpansMultipleTokensInPhrase() {
        // A single timed run covering several words is timed correctly when the
        // phrase keeps those words together (the common, line-fitting case).
        let words = [word("New York", 0, 0.6), word("rocks", 0.9, 1.2)]
        let phrases = CaptionBuilder.phrases(
            for: segment("New York rocks", 0, 1.2), words: words, fits: { _ in true }, minDuration: 0
        )
        #expect(phrases.map(\.text) == ["New York rocks"])
        #expect(phrases.map(\.start) == [0.0])
        #expect(phrases.map(\.end) == [1.2])
    }

    @Test func fallsBackToCharacterDistributionWhenNoTiming() {
        let words = [TranscriptionWord(text: "aaaa", start: nil, end: nil)]
        let phrases = CaptionBuilder.phrases(
            for: segment("aaaa bb", 0, 6), words: words, fits: { $0.count <= 4 }, minDuration: 0
        )
        #expect(phrases.map(\.start) == [0.0, 4.0])
        #expect(phrases.map(\.end) == [4.0, 6.0])
    }

    @Test func enforcesMinimumDurationAndShifts() {
        let phrases = CaptionBuilder.phrases(for: segment("aa bbbb", 0, 6), fits: { $0.count <= 4 }, minDuration: 3)
        #expect(phrases.map(\.start) == [0.0, 3.0])
        #expect(phrases.map(\.end) == [3.0, 7.0])
    }

    @Test func keepsOverlongSingleWord() {
        let phrases = CaptionBuilder.phrases(for: segment("supercalifragilistic", 0, 1), fits: { _ in false }, minDuration: 0)
        #expect(phrases.map(\.text) == ["supercalifragilistic"])
    }

    private let clip = Clip(mediaRef: "m", startFrame: 30, durationFrames: 120)

    @Test func mapsSecondsThroughClipPlacement() {
        let p = CaptionBuilder.Phrase(text: "hi", start: 1.0, end: 2.0)
        let specs = CaptionBuilder.specs(for: [p], sourceClip: clip, trackIndex: 0, fps: 30, style: TextStyle(), captionGroupId: "g1")
        #expect(specs.count == 1)
        #expect(specs[0].startFrame == 60)
        #expect(specs[0].durationFrames == 30)
        #expect(specs[0].captionGroupId == "g1")
    }

    @Test func clampsPhraseRunningPastClipEnd() {
        let p = CaptionBuilder.Phrase(text: "long", start: 1.0, end: 10.0)
        let specs = CaptionBuilder.specs(for: [p], sourceClip: clip, trackIndex: 0, fps: 30, style: TextStyle(), captionGroupId: nil)
        #expect(specs[0].startFrame == 60)
        #expect(specs[0].durationFrames == 90)
    }

    @Test func clampsPhraseSpanningTrimmedClip() {
        var trimmed = clip
        trimmed.trimStartFrame = 60
        let p = CaptionBuilder.Phrase(text: "full", start: 0.0, end: 10.0)
        let specs = CaptionBuilder.specs(for: [p], sourceClip: trimmed, trackIndex: 0, fps: 30, style: TextStyle(), captionGroupId: nil)
        #expect(specs.count == 1)
        #expect(specs[0].startFrame == 30)
        #expect(specs[0].durationFrames == 120)
    }

    @Test func transformForResolvesEachBox() {
        let p = CaptionBuilder.Phrase(text: "hi", start: 1.0, end: 2.0)
        let box = Transform(center: (0.5, 0.85), width: 0.4, height: 0.1)
        let specs = CaptionBuilder.specs(
            for: [p], sourceClip: clip, trackIndex: 0, fps: 30, style: TextStyle(),
            captionGroupId: nil, transformFor: { _ in box }
        )
        #expect(specs[0].transform == box)
    }

    @Test func dropsPhraseEntirelyBeforeTrimIn() {
        var trimmed = clip
        trimmed.trimStartFrame = 60
        let p = CaptionBuilder.Phrase(text: "gone", start: 0.5, end: 1.0)
        let specs = CaptionBuilder.specs(for: [p], sourceClip: trimmed, trackIndex: 0, fps: 30, style: TextStyle(), captionGroupId: nil)
        #expect(specs.isEmpty)
    }
}
