import Testing
@testable import PalmierPro

@Suite("Caption word grouping")
struct CaptionWordGroupingTests {

    private func word(_ t: String, _ s: Double, _ e: Double) -> TranscriptionWord {
        TranscriptionWord(text: t, start: s, end: e)
    }

    private var sixWords: [TranscriptionWord] {
        [word("a", 0, 0.3), word("b", 0.3, 0.6), word("c", 0.6, 0.9),
         word("d", 1.0, 1.3), word("e", 1.3, 1.6), word("f", 1.6, 1.9)]
    }

    @Test func groupsThreeWordsWithRealTimings() {
        let phrases = CaptionBuilder.phrases(fromWords: sixWords, wordsPerCaption: 3, minDuration: 0.05)
        #expect(phrases.count == 2)
        #expect(phrases[0].text == "a b c")
        #expect(phrases[0].start == 0)
        #expect(abs(phrases[0].end - 0.9) < 0.001)   // real last-word end, not char-distributed
        #expect(phrases[1].text == "d e f")
        #expect(abs(phrases[1].start - 1.0) < 0.001)
        #expect(abs(phrases[1].end - 1.9) < 0.001)
    }

    @Test func groupsSixWordsIntoOne() {
        let phrases = CaptionBuilder.phrases(fromWords: sixWords, wordsPerCaption: 6, minDuration: 0.05)
        #expect(phrases.count == 1)
        #expect(phrases[0].text == "a b c d e f")
    }

    @Test func breaksEarlyOnLongPause() {
        let words = [word("hello", 0, 0.4), word("there", 2.0, 2.4)] // 1.6s gap
        let phrases = CaptionBuilder.phrases(fromWords: words, wordsPerCaption: 6, minDuration: 0.05)
        #expect(phrases.count == 2)
    }

    @Test func emptyWordsProduceNoPhrases() {
        #expect(CaptionBuilder.phrases(fromWords: [], wordsPerCaption: 3, minDuration: 0.05).isEmpty)
    }
}
