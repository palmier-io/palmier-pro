import Foundation
import Testing
@testable import PalmierPro

@Suite("CaptionWordAnimation")
struct CaptionWordAnimationTests {
    @Test func popStartsHiddenThenScalesIn() {
        let anim = CaptionWordAnimation.pop
        let before = anim.appearance(at: 0, wordStartFrame: 5)
        #expect(before.opacity == 0)
        #expect(before.scale < 1)

        let during = anim.appearance(at: 6, wordStartFrame: 5)
        #expect(during.opacity > 0)
        #expect(during.scale > before.scale)

        let after = anim.appearance(at: 20, wordStartFrame: 5)
        #expect(after.opacity == 1)
        #expect(after.scale == 1)
    }

    @Test func staticShowsWordsOnlyAfterStart() {
        let anim = CaptionWordAnimation.none
        #expect(anim.appearance(at: 4, wordStartFrame: 5).opacity == 0)
        #expect(anim.appearance(at: 5, wordStartFrame: 5).opacity == 1)
    }
}

@Suite("Clip caption word reconcile")
struct ClipReconcileCaptionWordsTests {
    private func clip(content: String, words: [CaptionWordTiming]) -> Clip {
        var c = Clip(mediaRef: "m", startFrame: 0, durationFrames: 120)
        c.textContent = content
        c.captionWordAnimation = .pop
        c.captionWords = words
        return c
    }

    @Test func typoFixKeepsTimings() {
        var c = clip(content: "the pillow word", words: [
            CaptionWordTiming(text: "the", startFrame: 0, endFrame: 5),
            CaptionWordTiming(text: "pillow", startFrame: 5, endFrame: 10),
            CaptionWordTiming(text: "word", startFrame: 10, endFrame: 15),
        ])
        c.reconcileCaptionWords(to: "the filler word")
        #expect(c.captionWords?.map(\.text) == ["the", "filler", "word"])
        #expect(c.captionWords?.map(\.startFrame) == [0, 5, 10])
    }

    @Test func wordCountChangeDropsTimings() {
        var c = clip(content: "the filler word", words: [
            CaptionWordTiming(text: "the", startFrame: 0, endFrame: 5),
            CaptionWordTiming(text: "filler", startFrame: 5, endFrame: 10),
            CaptionWordTiming(text: "word", startFrame: 10, endFrame: 15),
        ])
        c.reconcileCaptionWords(to: "the filler")
        #expect(c.captionWords == nil)
    }
}

@Suite("CaptionBuilder word timings")
struct CaptionBuilderWordTimingTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionWord {
        TranscriptionWord(text: text, start: start, end: end)
    }

    @Test func attachesWordTimingsToPhrases() {
        let seg = TranscriptionSegment(text: "hello world", start: 0, end: 2)
        let words = [word("hello", 0, 0.8), word("world", 0.9, 2.0)]
        let phrases = CaptionBuilder.phrases(for: seg, words: words, fits: { _ in true }, minDuration: 0)
        #expect(phrases.count == 1)
        #expect(phrases[0].words.map(\.text) == ["hello", "world"])
        #expect(phrases[0].words.map(\.start) == [0, 0.9])
    }

    @Test func mergesSplitContractionRunsIntoPhraseTokens() {
        let seg = TranscriptionSegment(text: "don't know", start: 0, end: 2)
        let words = [
            word("don", 0, 0.4),
            word("t", 0.4, 0.5),
            word("know", 0.6, 2.0),
        ]
        let phrases = CaptionBuilder.phrases(for: seg, words: words, fits: { _ in true }, minDuration: 0)
        #expect(phrases.count == 1)
        #expect(phrases[0].words.map(\.text) == ["don't", "know"])
        #expect(phrases[0].words.map(\.start) == [0, 0.6])
        #expect(phrases[0].words.map(\.end) == [0.5, 2.0])

        let clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 60)
        let specs = CaptionBuilder.specs(
            for: phrases,
            sourceClip: clip,
            trackIndex: 0,
            fps: 30,
            style: TextStyle(),
            captionGroupId: "g",
            wordAnimation: .pop
        )
        #expect(specs[0].captionWords?.map(\.text) == ["don't", "know"])
        #expect(specs[0].captionWords?.count == 2)
    }

    @Test func specsIncludeCaptionWordsWhenAnimated() {
        let clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 120)
        let phrase = CaptionBuilder.Phrase(
            text: "hello world",
            start: 0,
            end: 2,
            words: [
                CaptionBuilder.WordTiming(text: "hello", start: 0, end: 0.8),
                CaptionBuilder.WordTiming(text: "world", start: 0.9, end: 2),
            ]
        )
        let specs = CaptionBuilder.specs(
            for: [phrase],
            sourceClip: clip,
            trackIndex: 0,
            fps: 30,
            style: TextStyle(),
            captionGroupId: "g1",
            wordAnimation: .pop
        )
        #expect(specs.count == 1)
        #expect(specs[0].captionWordAnimation == .pop)
        #expect(specs[0].captionWords?.map(\.text) == ["hello", "world"])
        #expect(specs[0].captionWords?.map(\.startFrame) == [0, 27])
    }

    @Test func trimmedClipKeepsEveryWordInOrder() {
        var clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 60)
        clip.trimStartFrame = 30
        let phrase = CaptionBuilder.Phrase(
            text: "alpha beta gamma",
            start: 0.5,
            end: 2.5,
            words: [
                CaptionBuilder.WordTiming(text: "alpha", start: 0.5, end: 0.9),
                CaptionBuilder.WordTiming(text: "beta", start: 1.5, end: 1.9),
                CaptionBuilder.WordTiming(text: "gamma", start: 2.4, end: 2.5),
            ]
        )
        let specs = CaptionBuilder.specs(
            for: [phrase], sourceClip: clip, trackIndex: 0, fps: 30,
            style: TextStyle(), captionGroupId: "g", wordAnimation: .pop
        )
        #expect(specs.count == 1)
        let words = specs[0].captionWords
        #expect(words?.map(\.text) == ["alpha", "beta", "gamma"])
        let starts = words?.map(\.startFrame) ?? []
        #expect(starts == starts.sorted())
        #expect(starts.first == 0)
    }

    @Test func noWordTimingsMeansNoAnimation() {
        let clip = Clip(mediaRef: "m", startFrame: 0, durationFrames: 60)
        let phrase = CaptionBuilder.Phrase(text: "hello world", start: 0, end: 2, words: [])
        let specs = CaptionBuilder.specs(
            for: [phrase], sourceClip: clip, trackIndex: 0, fps: 30,
            style: TextStyle(), captionGroupId: "g", wordAnimation: .pop
        )
        #expect(specs.count == 1)
        #expect(specs[0].captionWordAnimation == nil)
        #expect(specs[0].captionWords == nil)
    }
}
