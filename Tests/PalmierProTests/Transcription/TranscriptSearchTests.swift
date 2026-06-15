import Foundation
import Testing
@testable import PalmierPro

@Suite("TranscriptSearch")
struct TranscriptSearchTests {
    @Test func parsesTermsStrippingEdgePunctuation() {
        #expect(TranscriptSearch.terms(in: "  budget, meeting!  ") == ["budget", "meeting"])
        #expect(TranscriptSearch.terms(in: "don't stop") == ["don't", "stop"])
        #expect(TranscriptSearch.terms(in: "...") == [])
        #expect(TranscriptSearch.terms(in: "") == [])
    }

    @Test func matchesAllTermsAnyOrder() {
        let text = "We reviewed the Q3 budget at the morning meeting."
        #expect(TranscriptSearch.matches(text, terms: ["budget", "meeting"]))
        #expect(TranscriptSearch.matches(text, terms: ["meeting", "budget"]))
        #expect(!TranscriptSearch.matches(text, terms: ["budget", "harbor"]))
    }

    @Test func caseAndDiacriticInsensitiveAndPartialWord() {
        #expect(TranscriptSearch.matches("Visit the CAFÉ downtown", terms: ["cafe"]))
        #expect(TranscriptSearch.matches("she was running fast", terms: ["run"]))
    }
}
