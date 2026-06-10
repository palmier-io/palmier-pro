import Foundation
import Testing
@testable import PalmierPro

@Suite("TranscriptCache")
struct TranscriptCacheTests {
    private let full = TranscriptionResult(
        text: "Hello there. How are you. Fine thanks.",
        language: "en-US",
        words: [
            TranscriptionWord(text: "Hello", start: 0.0, end: 0.4),
            TranscriptionWord(text: "there", start: 0.4, end: 0.8),
            TranscriptionWord(text: "How", start: 5.0, end: 5.3),
            TranscriptionWord(text: "are", start: 5.3, end: 5.5),
            TranscriptionWord(text: "you", start: 5.5, end: 5.8),
            TranscriptionWord(text: "Fine", start: 10.0, end: 10.4),
            TranscriptionWord(text: "thanks", start: 10.4, end: 10.9),
        ],
        segments: [
            TranscriptionSegment(text: "Hello there.", start: 0.0, end: 0.8),
            TranscriptionSegment(text: "How are you.", start: 5.0, end: 5.8),
            TranscriptionSegment(text: "Fine thanks.", start: 10.0, end: 10.9),
        ]
    )

    @Test func filterKeepsOnlyOverlappingEntries() {
        let windowed = TranscriptCache.filter(full, to: 4.0...6.0)
        #expect(windowed.segments.map(\.text) == ["How are you."])
        #expect(windowed.words.map(\.text) == ["How", "are", "you"])
        #expect(windowed.text == "How are you.")
        #expect(windowed.language == "en-US")
    }

    @Test func filterIncludesBoundaryStraddlers() {
        let windowed = TranscriptCache.filter(full, to: 0.5...5.2)
        #expect(windowed.segments.map(\.text) == ["Hello there.", "How are you."])
    }

    @Test func resultRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(full)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        #expect(decoded.text == full.text)
        #expect(decoded.language == full.language)
        #expect(decoded.segments.count == full.segments.count)
        #expect(decoded.words.count == full.words.count)
        #expect(decoded.words[0].start == full.words[0].start)
    }
}
