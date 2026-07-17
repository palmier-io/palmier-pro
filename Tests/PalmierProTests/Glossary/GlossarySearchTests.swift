// Dual-layer spoken search (§2.4) and re-index survival for the glossary correction layer.
// refs feature/glossary

import Foundation
import Testing
@testable import PalmierPro

@Suite("GlossarySearch")
struct GlossarySearchTests {
    private func transcript(_ segments: [String]) -> TranscriptionResult {
        TranscriptionResult(
            text: segments.joined(separator: " "),
            language: "zh",
            words: [],
            segments: segments.enumerated().map { i, s in
                TranscriptionSegment(text: s, start: Double(i * 5), end: Double(i * 5 + 5))
            }
        )
    }

    private let corrector = GlossaryCorrector(terms: [
        GlossaryTerm(canonical: "陈嬢嬢", variants: ["陈娘娘"], provenance: "user", confidence: .declared),
    ])

    @Test func queryByCanonicalHitsViaCorrectedLayer() {
        // Raw transcript holds the mis-hearing; a query for the canonical still finds it.
        let hits = TranscriptSearch.rank(
            query: "陈嬢嬢",
            transcripts: [("a", transcript(["我们去陈娘娘家吃饭"]))],
            corrector: corrector
        )
        #expect(hits.count == 1)
        #expect(hits[0].text.contains("陈嬢嬢"))
    }

    @Test func queryByRawVariantHits() {
        let hits = TranscriptSearch.rank(
            query: "陈娘娘",
            transcripts: [("a", transcript(["我们去陈娘娘家吃饭"]))],
            corrector: corrector
        )
        #expect(hits.count == 1)
    }

    @Test func unrelatedRawGarbleStaysFindable() {
        // A one-off garble that never got a glossary entry must remain searchable by its raw spelling.
        let hits = TranscriptSearch.rank(
            query: "茶烟月色间",
            transcripts: [("a", transcript(["坐在茶烟月色间聊天"]))],
            corrector: corrector
        )
        #expect(hits.count == 1)
    }

    @Test func correctedHitsRankAboveRawOnly() {
        let hits = TranscriptSearch.rank(
            query: "陈嬢嬢",
            transcripts: [
                ("raw", transcript(["原文写作陈嬢嬢"])),      // already canonical → raw-only match
                ("corrected", transcript(["口误说成陈娘娘"])), // matches via corrected layer
            ],
            corrector: corrector
        )
        #expect(hits.count == 2)
        #expect(hits[0].assetID == "corrected")  // corrected layer ranked first
    }

    @Test func blackCitizensRegressionReturnedVerbatim() {
        // No glossary entry for "black citizens" — materialisation must not touch it.
        let empty = GlossaryCorrector(terms: [])
        let raw = TranscriptionResult(
            text: "the black citizens gathered",
            language: "en",
            words: [TranscriptionWord(text: "black", start: 0, end: 1)],
            segments: [TranscriptionSegment(text: "the black citizens gathered", start: 0, end: 3)]
        )
        let out = raw.applyingGlossary(empty)
        #expect(out.text == "the black citizens gathered")
        #expect(out.segments[0].text == "the black citizens gathered")
    }

    @Test func correctionsSurviveReindex() {
        // Simulate the library being re-indexed: a fresh raw result (new object) still corrects,
        // because corrections are additive and applied at read time.
        let freshRaw = transcript(["新的转写结果陈娘娘"])
        let out = freshRaw.applyingGlossary(corrector)
        #expect(out.segments[0].text == "新的转写结果陈嬢嬢")
    }
}
