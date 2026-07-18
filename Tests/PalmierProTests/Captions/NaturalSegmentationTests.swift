import Foundation
import NaturalLanguage
import Testing
@testable import PalmierPro

// Natural caption segmentation (default): sentence/clause breaks, word-boundary-only splits, and the
// fixedChars legacy pin. Covers the real code-switched regressions from a 42-min zh/en vlog.
@Suite("NaturalSegmentation")
struct NaturalSegmentationTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionWord {
        TranscriptionWord(text: text, start: start, end: end)
    }

    /// One TranscriptionWord per character, back to back — how CJK reaches the builder after piece split.
    private func cjkWords(_ text: String, step: Double = 0.5) -> [TranscriptionWord] {
        text.enumerated().map { i, c in
            TranscriptionWord(text: String(c), start: Double(i) * step, end: Double(i + 1) * step)
        }
    }

    /// Every NLTokenizer word token of the source must sit wholly inside one line — no line ends mid-token.
    private func assertTokensWhole(_ lines: [String], source: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = source
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            let token = String(source[range])
            #expect(lines.contains { $0.contains(token) }, "token \(token) split across lines", sourceLocation: sourceLocation)
            return true
        }
    }

    private func startsWithPunctuation(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return "。？！，、；….?!,".contains(first)
    }

    // MARK: - The three real regressions

    @Test func breaksAtSentenceMarkAndKeepsProperNounWhole() {
        let source = "好久没有开视频了。那我现在人在重庆西站在等着"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { $0.count <= 20 },   // both clauses fit width, so only the 。 forces a break
            minDuration: 0
        )
        let lines = phrases.map(\.text)

        #expect(lines == ["好久没有开视频了。", "那我现在人在重庆西站在等着"])
        #expect(lines.contains { $0.contains("重庆西站") })   // proper noun never split mid-word
        assertTokensWhole(lines, source: source)

        // Karaoke data survives: per-character word timings are still sliced from the transcript.
        #expect(phrases.allSatisfy { !$0.words.isEmpty })
        #expect(phrases[0].words.map(\.text) == ["好", "久", "没", "有", "开", "视", "频", "了"])
    }

    @Test func punctuationBindsLeftNeverStartsALine() {
        let source = "好久没有开视频了。那我现在人在重庆西站在等着"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { $0.count <= 6 },   // tight width forces multiple word-boundary breaks
            minDuration: 0
        )
        let lines = phrases.map(\.text)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { !startsWithPunctuation($0) })
        assertTokensWhole(lines, source: source)
    }

    @Test func mixedScriptSegmentsAtSentenceMarksKeepingEnglishWhole() {
        let words = [
            word("我掉得", 0.0, 0.6), word("really", 0.6, 1.0), word("low", 1.0, 1.3), word("。", 1.3, 1.35),
            word("oh", 1.4, 1.7), word("god", 1.7, 2.0), word("。", 2.0, 2.05),
        ]
        let phrases = CaptionBuilder.phrases(fromTimedWords: words, fits: { _ in true }, minDuration: 0)
        let lines = phrases.map(\.text)

        #expect(lines == ["我掉得 really low。", "oh god。"])
        for w in ["really", "low", "oh", "god"] {
            #expect(lines.contains { $0.contains(w) })   // English words stay whole
        }
        #expect(lines.allSatisfy { !startsWithPunctuation($0) })
    }

    // MARK: - Caps still respected

    @Test func maxWordsCapsCJKCharactersPerLine() {
        let source = "好久没有开视频了"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { _ in true },
            maxWords: 5,
            minDuration: 0
        )
        let lines = phrases.map(\.text)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { GlossaryText.cjkCount($0) <= 5 })
        assertTokensWhole(lines, source: source)
    }

    @Test func maxWordsCapsLatinWordsPerLine() {
        let phrases = CaptionBuilder.phrases(
            for: TranscriptionSegment(text: "one two three four five", start: 0, end: 5),
            fits: { _ in true },
            maxWords: 2,
            minDuration: 0
        )
        let lines = phrases.map(\.text)
        #expect(lines == ["one two", "three four", "five"])
    }

    @Test func widthFitStillRespectedInNaturalMode() {
        let phrases = CaptionBuilder.phrases(
            for: TranscriptionSegment(text: "alpha beta gamma delta", start: 0, end: 4),
            fits: { $0.count <= 10 },
            minDuration: 0
        )
        #expect(phrases.map(\.text).allSatisfy { $0.count <= 10 })
    }

    // MARK: - Legacy pin

    @Test func fixedCharsReproducesLegacyGuillotine() {
        // The old recursive width split: spaced CJK characters, cut mid-run irrespective of meaning.
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords("好久没有开"),
            fits: { $0.count <= 3 },
            minDuration: 0,
            segmentation: .fixedChars
        )
        #expect(phrases.map(\.text) == ["好 久", "没", "有 开"])
    }
}
