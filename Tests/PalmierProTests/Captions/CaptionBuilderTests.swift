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
