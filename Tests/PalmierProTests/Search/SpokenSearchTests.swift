import Foundation
import Testing
@testable import PalmierPro

@Suite("SpokenSearch.Keyword")
struct KeywordTierTests {
    @Test func parsesTermsStrippingEdgePunctuation() {
        #expect(SpokenSearch.Keyword.terms(in: "  budget, meeting!  ") == ["budget", "meeting"])
        #expect(SpokenSearch.Keyword.terms(in: "don't stop") == ["don't", "stop"])
        #expect(SpokenSearch.Keyword.terms(in: "...") == [])
        #expect(SpokenSearch.Keyword.terms(in: "") == [])
    }

    @Test func matchesAllTermsAnyOrder() {
        let text = "We reviewed the Q3 budget at the morning meeting."
        #expect(SpokenSearch.Keyword.matches(text, terms: ["budget", "meeting"]))
        #expect(SpokenSearch.Keyword.matches(text, terms: ["meeting", "budget"]))
        #expect(!SpokenSearch.Keyword.matches(text, terms: ["budget", "harbor"]))
    }

    @Test func caseAndDiacriticInsensitiveAndPartialWord() {
        #expect(SpokenSearch.Keyword.matches("Visit the CAFÉ downtown", terms: ["cafe"]))
        #expect(SpokenSearch.Keyword.matches("she was running fast", terms: ["run"]))
    }
}

@Suite("SpokenSearch merge")
struct SpokenSearchMergeTests {
    private func transcript(segments: [(String, Double, Double)]) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.map(\.0).joined(separator: " "), language: "en",
            words: [],
            segments: segments.map { TranscriptionSegment(text: $0.0, start: $0.1, end: $0.2) }
        )
    }

    @Test func keywordOutranksSemanticAndDedupes() {
        let keyword = [SpokenSearch.Hit(assetID: "a", start: 5, end: 8, text: "the budget doubled")]
        let semantic = [
            VisualSearch.Hit(assetID: "a", time: 5, shotStart: 5, shotEnd: 8, score: 0.9),   // dupe of keyword hit
            VisualSearch.Hit(assetID: "a", time: 12, shotStart: 12, shotEnd: 15, score: 0.8),
        ]
        let transcripts = ["a": transcript(segments: [
            ("the budget doubled", 5, 8), ("our spending grew a lot", 12, 15),
        ])]
        let hits = SpokenSearch.merge(keyword: keyword, semantic: semantic, transcripts: transcripts, limit: 10)
        #expect(hits.count == 2)
        #expect(hits[0].text == "the budget doubled")
        #expect(hits[1].text == "our spending grew a lot")
    }

    @Test func respectsLimitAndDropsTextlessHits() {
        let semantic = [
            VisualSearch.Hit(assetID: "a", time: 1, shotStart: 1, shotEnd: 2, score: 0.9),
            VisualSearch.Hit(assetID: "b", time: 3, shotStart: 3, shotEnd: 4, score: 0.8),  // no transcript loaded
        ]
        let transcripts = ["a": transcript(segments: [("hello there", 1, 2)])]
        let hits = SpokenSearch.merge(keyword: [], semantic: semantic, transcripts: transcripts, limit: 1)
        #expect(hits.map(\.text) == ["hello there"])
    }
}

@Suite("SpokenWindowBuilder")
struct SpokenWindowBuilderTests {
    private func transcript(_ segs: [(String, Double, Double)]) -> TranscriptionResult {
        TranscriptionResult(
            text: segs.map(\.0).joined(separator: " "), language: "en", words: [],
            segments: segs.map { TranscriptionSegment(text: $0.0, start: $0.1, end: $0.2) }
        )
    }

    @Test func mergesShortInterjectionsIntoContextWindows() {
        // Three short back-to-back utterances merge into one window with real context.
        let windows = SpokenWindowBuilder.windows(from: transcript([
            ("Right.", 0, 1), ("Yeah absolutely.", 1, 2.5), ("I switched to steak and eggs.", 2.5, 5),
        ]))
        #expect(windows.count == 1)
        #expect(windows[0].text == "Right. Yeah absolutely. I switched to steak and eggs.")
        #expect(windows[0].start == 0 && windows[0].end == 5)
    }

    @Test func breaksOnLongGapAndCaps() {
        // A >1s gap starts a new window; a long run caps near maxDuration.
        let windows = SpokenWindowBuilder.windows(from: transcript([
            ("first thought here", 0, 3), ("much later point", 10, 13),
        ]))
        #expect(windows.count == 2)
    }

    @Test func dropsPunctuationOnlySegments() {
        let windows = SpokenWindowBuilder.windows(from: transcript([("...", 0, 1), (".", 1, 2)]))
        #expect(windows.isEmpty)
    }

    @Test func windowTextReconstructsFromTranscript() {
        let t = transcript([("the budget", 5, 6), ("doubled this year", 6, 8)])
        #expect(SpokenSearch.windowText(t, start: 5, end: 8) == "the budget doubled this year")
        #expect(SpokenSearch.windowText(t, start: 100, end: 110) == nil)
    }
}

@Suite("SpokenModel families")
struct SpokenModelTests {
    @Test func mapsWesternLanguagesToLatin() {
        guard SpokenModel.latin.revision > 0 else { return }
        #expect(SpokenModel.family(forBCP47: "en-US") == .latin)
        #expect(SpokenModel.family(forBCP47: "fr-FR") == .latin)
        #expect(SpokenModel.family(forBCP47: "de") == .latin)
    }

    @Test func mapsCJKLanguagesToCJK() {
        guard SpokenModel.cjk.revision > 0 else { return }
        #expect(SpokenModel.family(forBCP47: "zh-CN") == .cjk)
        #expect(SpokenModel.family(forBCP47: "ja-JP") == .cjk)
        #expect(SpokenModel.family(forBCP47: "ko") == .cjk)
    }

    @Test func unsupportedAndMissingMapToNil() {
        // Cyrillic/Arabic have no on-device assets in our V1 set.
        #expect(SpokenModel.family(forBCP47: "ru-RU") == nil)
        #expect(SpokenModel.family(forBCP47: nil) == nil)
    }
}

/// Requires the OS contextual-embedding assets; exits early when absent.
@Suite("SpokenEmbedder", .serialized)
struct SpokenEmbedderTests {
    @Test(.enabled(if: SpokenModel.latin.revision > 0)) func vectorsAreNormalizedAndSemantic() async throws {
        guard let a = await SpokenEmbedder.shared.vector(for: "we discussed the quarterly budget", family: .latin) else {
            return // assets not downloaded on this machine
        }
        let norm = a.reduce(0) { $0 + $1 * $1 }
        #expect(abs(norm - 1) < 0.01)

        let b = try #require(await SpokenEmbedder.shared.vector(for: "a conversation about company finances", family: .latin))
        let c = try #require(await SpokenEmbedder.shared.vector(for: "a red sports car drifting", family: .latin))
        func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(dot(a, b) > dot(a, c), "related sentences should score higher")
    }
}
