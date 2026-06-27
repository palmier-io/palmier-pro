import Testing
@testable import PalmierPro

@Suite("Caption max words per caption")
struct CaptionMaxWordsTests {

    private func word(_ t: String, _ s: Double, _ e: Double) -> TranscriptionWord {
        TranscriptionWord(text: t, start: s, end: e)
    }

    private var sixWords: [TranscriptionWord] {
        [word("a", 0, 0.3), word("b", 0.3, 0.6), word("c", 0.6, 0.9),
         word("d", 1.0, 1.3), word("e", 1.3, 1.6), word("f", 1.6, 1.9)]
    }

    @Test func capsAtThreeWordsWithRealTimings() {
        let p = CaptionBuilder.phrases(words: sixWords, maxWords: 3, minDuration: 0.05)
        #expect(p.count == 2)
        #expect(p[0].text == "a b c")
        #expect(p[0].start == 0)
        #expect(abs(p[0].end - 0.9) < 0.001)
        #expect(p[1].text == "d e f")
    }

    @Test func sixWordsFitOneCaption() {
        #expect(CaptionBuilder.phrases(words: sixWords, maxWords: 6, minDuration: 0.05).count == 1)
    }

    @Test func longPauseSplitsEarly() {
        let words = [word("hello", 0, 0.4), word("there", 2.0, 2.4)] // 1.6s gap
        #expect(CaptionBuilder.phrases(words: words, maxWords: 6, minDuration: 0.05).count == 2)
    }

    @Test func emptyWordsProduceNothing() {
        #expect(CaptionBuilder.phrases(words: [], maxWords: 3, minDuration: 0.05).isEmpty)
    }
}
