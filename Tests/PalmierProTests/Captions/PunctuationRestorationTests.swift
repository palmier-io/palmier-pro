import Foundation
import Testing
@testable import PalmierPro

// The Qwen3 punctuation seam: a restorer (faked here) re-punctuates a chunk's text, and the engine
// folds those marks back onto the preceding piece without moving any timing. Real model inference is
// not unit-tested — only the injectable seam and the deterministic distribution are.
@Suite("PunctuationRestoration")
struct PunctuationRestorationTests {
    /// Inserts 。 after 了 and ， after 我 — enough to prove marks land on the preceding piece.
    private struct FakeRestorer: PunctuationRestoring {
        func restore(_ text: String) async -> String {
            text.replacingOccurrences(of: "了", with: "了。").replacingOccurrences(of: "我", with: "我，")
        }
    }

    /// Stands in for an offline/unavailable model: returns the input verbatim.
    private struct PassthroughRestorer: PunctuationRestoring {
        func restore(_ text: String) async -> String { text }
    }

    @Test func foldsCJKMarksOntoPrecedingPiece() async {
        let raw = "好久了那我"
        let restored = await FakeRestorer().restore(raw)
        let pieces = Qwen3ASREngine.punctuatedPieces(raw: raw, restored: restored)
        #expect(pieces == ["好", "久", "了。", "那", "我，"])
        // Piece count matches the unpunctuated stream, so aligned word timings never shift.
        #expect(pieces.count == 5)
    }

    @Test func latinMarksStayAttachedToTheirWord() {
        let pieces = Qwen3ASREngine.punctuatedPieces(raw: "hello world", restored: "hello, world.")
        #expect(pieces == ["hello,", "world."])
    }

    @Test func unavailableRestorerIsUnpunctuatedPassthrough() async {
        let raw = "好久了那我"
        let restored = await PassthroughRestorer().restore(raw)
        let pieces = Qwen3ASREngine.punctuatedPieces(raw: raw, restored: restored)
        #expect(pieces == ["好", "久", "了", "那", "我"])
    }

    @Test func alteredCharactersFallBackToRaw() {
        // A restorer that changed base characters (not just inserted marks) is rejected wholesale.
        let pieces = Qwen3ASREngine.punctuatedPieces(raw: "好久", restored: "好X久")
        #expect(pieces == ["好", "久"])
    }

    @Test func leadingMarkWithNothingToBindIsDropped() {
        // A mark the model puts before the first piece has no preceding token to bind to, so it's
        // dropped rather than fabricating a standalone punctuation word.
        let pieces = Qwen3ASREngine.punctuatedPieces(raw: "好久", restored: "，好久")
        #expect(pieces == ["好", "久"])
    }

    /// Reproduces the ct-transformer zh-en failure: it appends a CJK mark after every Latin mark the
    /// ASR already emitted (`.` → `.。`, `,` → `,，`, `:` → `:，`). The fold must merge, not double.
    private struct DoublingRestorer: PunctuationRestoring {
        func restore(_ text: String) async -> String {
            text
                .replacingOccurrences(of: ".", with: ".。")
                .replacingOccurrences(of: ",", with: ",，")
                .replacingOccurrences(of: ":", with: ":，")
        }
    }

    /// Adds CJK terminals to an otherwise unpunctuated CJK stream — the case the feature exists for.
    private struct CJKRestorer: PunctuationRestoring {
        func restore(_ text: String) async -> String {
            text.replacingOccurrences(of: "了", with: "了，").replacingOccurrences(of: "站", with: "站。")
        }
    }

    // Real cached English from the 2026-07-15 zh/en vlog report, before doubling was fixed.
    private static let realEnglish = [
        "This is sufficient. Oh, okay.",
        "What I don't like about it: if you want smoked meat, you have to wait.",
        "Right, so that's the plan.",
        "Yeah. That works.",
    ]

    @Test(arguments: realEnglish)
    func alreadyPunctuatedEnglishIsNeverDoubled(_ raw: String) async {
        let restored = await DoublingRestorer().restore(raw)
        let pieces = Qwen3ASREngine.punctuatedPieces(raw: raw, restored: restored)
        let joined = pieces.joined(separator: " ")
        // No CJK mark leaks onto Latin text, so no `.。` / `,，` / `:，` pair can exist.
        #expect(!joined.contains("。"))
        #expect(!joined.contains("，"))
        // The ASR's own base text and Latin marks survive unchanged.
        #expect(pieces == Qwen3ASREngine.punctuatedPieces(raw: raw, restored: raw))
    }

    @Test func unpunctuatedCJKStreamComesBackPunctuated() async {
        let raw = "好久没有开视频了那我现在人在重庆西站"
        let restored = await CJKRestorer().restore(raw)
        let pieces = Qwen3ASREngine.punctuatedPieces(raw: raw, restored: restored)
        // Piece count matches the unpunctuated stream, so aligned word timings never shift.
        #expect(pieces.count == raw.count)
        let joined = pieces.joined()
        #expect(joined.contains("了，"))
        #expect(joined.contains("站。"))
    }

    @Test func internalLatinPunctuationIsNotReAppended() {
        // Marks inside a Latin run (apostrophe, abbreviation dots) stay put and are not folded on again.
        #expect(Qwen3ASREngine.punctuatedPieces(raw: "don't stop", restored: "don't stop.")
            == ["don't", "stop."])
        #expect(Qwen3ASREngine.punctuatedPieces(raw: "the U.S. team", restored: "the U.S. team.")
            == ["the", "U.S.", "team."])
    }
}
