import Foundation
import Testing
@testable import PalmierPro

@Suite("CaptionBuilder")
struct CaptionBuilderTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionWord {
        TranscriptionWord(text: text, start: start, end: end, type: "word", speakerId: nil)
    }

    @Test func breaksWhenLineOverflowsWidth() {
        let words = [word("a", 0, 0.3), word("b", 0.3, 0.6), word("c", 0.6, 0.9), word("dd", 0.9, 1.2)]
        let phrases = CaptionBuilder.group(words, fits: { $0.count <= 7 }, hardWordCap: 100, splitGap: 100)
        #expect(phrases.map(\.text) == ["a b c", "dd"])
    }

    @Test func capsAtHardWordCap() {
        let words = (0..<6).map { word("w\($0)", Double($0) * 0.1, Double($0) * 0.1 + 0.05) }
        let phrases = CaptionBuilder.group(words, fits: { _ in true }, hardWordCap: 3, splitGap: 100)
        #expect(phrases.map(\.text) == ["w0 w1 w2", "w3 w4 w5"])
    }

    @Test func sentencePunctuationBreaks() {
        let words = [word("Hello", 0, 0.4), word("there.", 0.4, 0.8), word("Next", 1.0, 1.4)]
        let phrases = CaptionBuilder.group(words, fits: { _ in true }, hardWordCap: 100, splitGap: 100)
        #expect(phrases.map(\.text) == ["Hello there.", "Next"])
    }

    @Test func silenceGapBreaks() {
        let words = [word("a", 0, 0.3), word("b", 0.4, 0.7), word("c", 2.0, 2.3)]
        let phrases = CaptionBuilder.group(words, fits: { _ in true }, hardWordCap: 100, splitGap: 0.8)
        #expect(phrases.map(\.text) == ["a b", "c"])
    }

    @Test func phraseCarriesStartAndEnd() {
        let phrases = CaptionBuilder.group([word("a", 0.5, 0.9), word("b", 0.9, 1.4)], fits: { _ in true })
        #expect(phrases.count == 1)
        #expect(phrases[0].start == 0.5)
        #expect(phrases[0].end == 1.4)
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
