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
}
