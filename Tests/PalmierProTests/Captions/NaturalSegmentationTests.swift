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

    /// All phrase text concatenated, spacing removed — the content, independent of where lines break.
    private func content(_ phrases: [CaptionBuilder.Phrase]) -> String {
        phrases.map(\.text).joined().replacingOccurrences(of: " ", with: "")
    }

    // MARK: - The three real regressions

    @Test func breaksAtSentenceMarkAndKeepsProperNounWhole() {
        let source = "好久没有开照片了。那我现在人在城南西站在等着"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { $0.count <= 20 },   // both clauses fit width, so only the 。 forces a break
            minDuration: 0
        )
        let lines = phrases.map(\.text)

        #expect(lines == ["好久没有开照片了。", "那我现在人在城南西站在等着"])
        #expect(lines.contains { $0.contains("城南西站") })   // proper noun never split mid-word
        assertTokensWhole(lines, source: source)

        // Karaoke data survives: per-character word timings are still sliced from the transcript.
        #expect(phrases.allSatisfy { !$0.words.isEmpty })
        #expect(phrases[0].words.map(\.text) == ["好", "久", "没", "有", "开", "照", "片", "了"])
    }

    @Test func protectedTermStaysWholeUnderTightCap() {
        // Sibling to the token-seam pin below: with 城南西站 protected, a tight cap breaks BEFORE the
        // term instead of at the 城南|西站 seam — the earlier accepted limitation, now guaranteed away.
        let source = "那我现在人在城南西站在等着"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { _ in true },
            maxWords: 4,
            minDuration: 0,
            protectedPhrases: ["城南西站"]
        )
        let lines = phrases.map(\.text)
        #expect(lines.count > 1)
        #expect(lines.contains { $0.contains("城南西站") })
        #expect(lines.allSatisfy { !($0.contains("城南") && !$0.contains("城南西站")) })
        assertTokensWhole(lines, source: source)
    }

    @Test func protectedTermBreaksBeforeItAtWidthBoundary() {
        // A width cap the term alone nearly fills: the line breaks before 城南西站, term stays whole.
        let source = "我在城南西站"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { $0.count <= 4 },
            minDuration: 0,
            protectedPhrases: ["城南西站"]
        )
        let lines = phrases.map(\.text)
        #expect(lines == ["我在", "城南西站"])
    }

    @Test func punctuatedOpeningLineKeepsWholePhrasesAndProtectsTerm() {
        // The report's opening line: punctuated + natural + 城南西站 protected → whole-phrase lines,
        // no mid-term split, no sentence-crossing.
        let source = "好久没有拍照片了。那我现在人在城南西站在等着"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { $0.count <= 20 },
            minDuration: 0,
            protectedPhrases: ["城南西站"]
        )
        let lines = phrases.map(\.text)
        #expect(lines == ["好久没有拍照片了。", "那我现在人在城南西站在等着"])
        #expect(lines.contains { $0.contains("城南西站") })
        assertTokensWhole(lines, source: source)
    }

    @Test func hardBreaksAtSpeechPauseWithoutPunctuation() {
        // Unpunctuated char stream with a 15-frame (0.5s @30fps) gap before 我: the pause alone must
        // force a break, and nothing merges across it.
        let words = [
            word("好", 0.0, 0.2), word("久", 0.2, 0.4), word("没", 0.4, 0.6),
            word("我", 1.1, 1.3), word("肯", 1.3, 1.5), word("定", 1.5, 1.7),
        ]
        let phrases = CaptionBuilder.phrases(fromTimedWords: words, fits: { _ in true }, minDuration: 0)
        #expect(phrases.map(\.text) == ["好久没", "我肯定"])
    }

    @Test func naturalNeverDropsContentAcrossPause() {
        // Segmentation may differ between modes; content may never. A zero-duration word isolated by a
        // pause split (evaluator repro: 好久 <pause> 嗯) must survive, not vanish into an empty run.
        let inputs: [[TranscriptionWord]] = [
            [word("好", 0.0, 0.3), word("久", 0.3, 0.6), word("嗯", 1.4, 1.4)],
            [word("好", 0.0, 0.3), word("久", 0.3, 0.6), word("我", 1.1, 1.3), word("肯", 1.3, 1.5)],
            cjkWords("好久没有开照片了"),
        ]
        for words in inputs {
            let natural = CaptionBuilder.phrases(fromTimedWords: words, fits: { _ in true }, minDuration: 0.7)
            let fixed = CaptionBuilder.phrases(
                fromTimedWords: words, fits: { _ in true }, minDuration: 0.7, segmentation: .fixedChars)
            #expect(content(natural) == content(fixed), "content diverged for \(words.map(\.text).joined())")
            #expect(!content(natural).isEmpty)
        }
    }

    @Test func pauseOverridesPhraseProtection() {
        // Documented precedence: a real pause inside a protected term splits it (silence mid-term
        // implies the match was wrong). Pinned so it stays a decision, not an accident.
        let words = [
            word("城", 0.0, 0.3), word("南", 0.3, 0.6),
            word("西", 1.2, 1.5), word("站", 1.5, 1.8),   // 0.6s pause before 西
        ]
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: words,
            fits: { _ in true },
            minDuration: 0,
            protectedPhrases: ["城南西站"]
        )
        #expect(phrases.map(\.text) == ["城南", "西站"])
    }

    @Test func subThresholdGapDoesNotBreak() {
        // A gap below the pause threshold (0.2s) is inter-word micro-silence, not a break.
        let words = [
            word("好", 0.0, 0.2), word("久", 0.2, 0.4),
            word("没", 0.6, 0.8), word("有", 0.8, 1.0),
        ]
        let phrases = CaptionBuilder.phrases(fromTimedWords: words, fits: { _ in true }, minDuration: 0)
        #expect(phrases.map(\.text) == ["好久没有"])
    }

    @Test func tightCapSplitsAtTokenSeamsNotMidToken() {
        // Accepted limitation: under a tight cap a proper noun may split at the 城南|西站 token seam
        // (NLTokenizer sees two words) — but never mid-character, and each token stays whole.
        let source = "那我现在人在城南西站在等着"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { _ in true },
            maxWords: 4,
            minDuration: 0
        )
        let lines = phrases.map(\.text)
        #expect(lines.count > 1)   // a tight cap forces multiple lines
        #expect(lines.allSatisfy { GlossaryText.cjkCount($0) <= 4 })
        assertTokensWhole(lines, source: source)
        #expect(lines.contains { $0.contains("城南") })
        #expect(lines.contains { $0.contains("西站") })
    }

    @Test func punctuationBindsLeftNeverStartsALine() {
        let source = "好久没有开照片了。那我现在人在城南西站在等着"
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
            word("我唱得", 0.0, 0.6), word("really", 0.6, 1.0), word("low", 1.0, 1.3), word("。", 1.3, 1.35),
            word("oh", 1.4, 1.7), word("god", 1.7, 2.0), word("。", 2.0, 2.05),
        ]
        let phrases = CaptionBuilder.phrases(fromTimedWords: words, fits: { _ in true }, minDuration: 0)
        let lines = phrases.map(\.text)

        #expect(lines == ["我唱得 really low。", "oh god。"])
        for w in ["really", "low", "oh", "god"] {
            #expect(lines.contains { $0.contains(w) })   // English words stay whole
        }
        #expect(lines.allSatisfy { !startsWithPunctuation($0) })
    }

    // MARK: - Caps still respected

    @Test func maxWordsCapsCJKCharactersPerLine() {
        let source = "好久没有开照片了"
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

    // MARK: - Punctuation-only runs (D5)

    @Test func punctuationOnlyRunProducesOneSaneLine() {
        // "。。。！！！" must not explode into one line per mark.
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords("。。。！！！"),
            fits: { _ in true },
            minDuration: 0
        )
        #expect(phrases.map(\.text) == ["。。。！！！"])
    }

    @Test func punctuationRunKeepsAcousticTimingForRealWords() {
        // A stray punctuation run between words must not collapse the segment to distribute() and
        // discard every real word's transcript timing.
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords("好。。。久"),
            fits: { _ in true },
            minDuration: 0
        )
        #expect(phrases.map(\.text) == ["好。。。", "久"])
        #expect(phrases.first?.words.map(\.text) == ["好"])
        #expect(phrases.first?.start == 0.0)
        #expect(phrases.first?.end == 0.5)     // acoustic span of 好, not an even split
        #expect(phrases.last?.start == 2.0)    // 久 is the 5th char → 2.0s in
        #expect(phrases.last?.end == 2.5)
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

    @Test func punctuationDrivesBreaksButIsStrippedFromDisplay() {
        // Bug report: marks rendered on screen while the width cap decided breaks. Inverted: marks
        // decide breaks (with maxWords only an upper bound), then stripCJK removes them from display.
        let source = "好久没有拍照片了。那我现在人在城南西站在等着和我朋友，还有我们的外地摄影师小哥。他来这里玩"
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: cjkWords(source),
            fits: { $0.count <= 14 },
            maxWords: 14,
            minDuration: 0,
            protectedPhrases: ["城南西站"],
            punctuation: .stripCJK
        )
        let lines = phrases.map(\.text)
        #expect(lines.first == "好久没有拍照片了")
        #expect(lines.allSatisfy { !$0.contains("。") && !$0.contains("，") })
        #expect(lines.allSatisfy { $0.count <= 14 })
        #expect(lines.allSatisfy { $0.count >= 2 }, "no single-particle lines like 了")
        #expect(lines.filter { $0.contains("城南西站") }.count == 1, "protected term whole in one line")
        #expect(lines.joined() == source.replacingOccurrences(of: "。", with: "").replacingOccurrences(of: "，", with: ""))
    }

    @Test func latinPunctuationSurvivesStripCJK() {
        let phrases = CaptionBuilder.phrases(
            fromTimedWords: [
                word("Yo,", 0.0, 0.3), word("what's", 0.3, 0.6), word("up?", 0.6, 0.9),
            ],
            fits: { $0.count <= 30 },
            minDuration: 0,
            punctuation: .stripCJK
        )
        // Clause breaks may split at the comma; the policy contract is that Latin marks stay VISIBLE.
        #expect(phrases.map(\.text).joined(separator: " ") == "Yo, what's up?")
    }

    @MainActor
    @Test func resyncProfileMaxWordsReachesEngineCreations() {
        // Bug report: caption_style typography.maxWords was ignored by resync — inferredMaxWords from
        // legacy clips won. The override must take precedence when supplied.
        #expect(CaptionResyncEngine.joinWords([
            WordTiming(text: "拍照片了。", startFrame: 0, endFrame: 30),
        ], punctuation: .stripCJK) == "拍照片了")
    }
}
