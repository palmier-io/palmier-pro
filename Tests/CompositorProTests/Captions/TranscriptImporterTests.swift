import Foundation
import Testing
@testable import CompositorPro

@Suite("Transcript import")
struct TranscriptImporterTests {
    @Test func parsesSRTCues() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        First line.

        2
        00:00:04,000 --> 00:00:06,000
        Second line.
        Continued.
        """
        let segments = try TranscriptImporter.parse(srt, fileExtension: "srt", durationSeconds: 10)
        #expect(segments.count == 2)
        #expect(segments[0].startSeconds == 1)
        #expect(segments[0].endSeconds == 3.5)
        #expect(segments[0].text == "First line.")
        #expect(segments[1].text == "Second line. Continued.")
    }

    @Test func parsesVTTCuesWithDotsAndHeader() throws {
        let vtt = """
        WEBVTT

        00:00:00.500 --> 00:00:02.000
        Hello.

        00:02.000 --> 00:04.250
        Short form timestamp.
        """
        let segments = try TranscriptImporter.parse(vtt, fileExtension: "vtt", durationSeconds: 10)
        #expect(segments.count == 2)
        #expect(segments[0].startSeconds == 0.5)
        #expect(abs(segments[1].startSeconds - 2) < 0.001)
        #expect(abs(segments[1].endSeconds - 4.25) < 0.001)
    }

    @Test func plainTextIsSpreadEvenly() throws {
        let segments = try TranscriptImporter.parse("One\nTwo\nThree", fileExtension: "txt", durationSeconds: 30)
        #expect(segments.count == 3)
        #expect(segments[0] == .init(startSeconds: 0, endSeconds: 10, text: "One"))
        #expect(segments[2] == .init(startSeconds: 20, endSeconds: 30, text: "Three"))
    }

    @Test func invalidInputIsRefused() {
        #expect(throws: TranscriptImportError.self) {
            try TranscriptImporter.parse("   ", fileExtension: "txt", durationSeconds: 10)
        }
        #expect(throws: TranscriptImportError.self) {
            try TranscriptImporter.parse("1\nnot a timestamp\nText", fileExtension: "srt", durationSeconds: 10)
        }
        #expect(throws: TranscriptImportError.self) {
            try TranscriptImporter.parse("text", fileExtension: "doc", durationSeconds: 10)
        }
    }

    @Test func mergeSkipsDuplicateRanges() {
        let existing = [TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "One")]
        let imported = [
            TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "One (again)"),
            TranscriptSegment(startSeconds: 2, endSeconds: 4, text: "Two"),
        ]
        let merged = TranscriptImporter.merge(imported, into: existing)
        #expect(merged.count == 2)
        #expect(merged.map(\.text) == ["One", "Two"])
    }
}
