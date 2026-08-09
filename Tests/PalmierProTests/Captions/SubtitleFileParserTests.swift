import CoreGraphics
import Foundation
import Testing
@testable import PalmierPro

@Suite struct SubtitleFileParserTests {
    @Test func parsesSRTToleratingBOMCRLFDotMillisMissingIndicesAndOutOfOrderCues() throws {
        let srt = "\u{FEFF}1\r\n00:01:00.250 --> 00:01:02,000\r\nLine one\r\nLine two\r\n\r\n"
            + "00:00:01,000 --> 00:00:02,500\r\nFirst.\r\n\r\n"
            + "3\r\n00:00:07,000 --> 00:00:08,000\r\n<i></i>\r\n"
        let cues = try SubtitleFileParser.parse(srt, format: .srt)
        #expect(cues == [
            SubtitleCue(text: "First.", startSeconds: 1.0, endSeconds: 2.5),
            SubtitleCue(text: "Line one\nLine two", startSeconds: 60.25, endSeconds: 62.0),
        ])
    }

    @Test func parsesWebVTTHeaderCommentBlocksIdentifiersAndSettings() throws {
        let vtt = """
        WEBVTT - Test file
        Kind: captions

        NOTE
        This comment block is skipped.

        STYLE
        ::cue { color: red }

        intro
        00:05.000 --> 00:07.500 align:start line:0
        <v Speaker><i>Styled</i> &amp; <00:00:06.500>timed</v>{\\an8}

        01:00:00.000 --> 01:00:01.000
        Escapes: &lt;tag&gt; &amp;lt;
        """
        let cues = try SubtitleFileParser.parse(vtt, format: .webVTT)
        #expect(cues == [
            SubtitleCue(text: "Styled & timed", startSeconds: 5.0, endSeconds: 7.5),
            SubtitleCue(text: "Escapes: <tag> &lt;", startSeconds: 3600.0, endSeconds: 3601.0),
        ])
    }

    @Test(arguments: [
        ("1\n00:00:xx,000 --> 00:00:01,000\nBad start.", 2),
        ("1\n00:00:01,000 --> 00:00:01,000\nEnd not after start.", 2),
        ("1\n00:75:00,000 --> 00:76:00,000\nMinutes out of range.", 2),
        ("1\n00:00:01,0000 --> 00:00:02,000\nToo many millisecond digits.", 2),
        ("No timing line at all.", 1),
    ])
    func malformedCueThrows(_ srt: String, atLine line: Int) {
        #expect(throws: SubtitleFileParser.ParseError.malformedCue(line: line)) {
            try SubtitleFileParser.parse(srt, format: .srt)
        }
    }

    @Test func treatsKeywordPrefixedIdentifiersAsCuesNotComments() throws {
        let vtt = "WEBVTT\n\nNOTE123\n00:01.000 --> 00:02.000\nA cue, not a comment.\n"
        let cues = try SubtitleFileParser.parse(vtt, format: .webVTT)
        #expect(cues == [SubtitleCue(text: "A cue, not a comment.", startSeconds: 1.0, endSeconds: 2.0)])

        #expect(throws: SubtitleFileParser.ParseError.missingWebVTTHeader) {
            try SubtitleFileParser.parse("WEBVTTjunk\n\n00:01.000 --> 00:02.000\nBad header.", format: .webVTT)
        }
    }

    @Test func rejectsCuesMissingTheirBlankLineSeparator() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nFirst.\n2\n00:00:03,000 --> 00:00:04,000\nSwallowed.\n"
        #expect(throws: SubtitleFileParser.ParseError.malformedCue(line: 5)) {
            try SubtitleFileParser.parse(srt, format: .srt)
        }
    }

    @Test func rejectsMissingHeaderEmptyFilesAndUnknownExtensions() {
        #expect(throws: SubtitleFileParser.ParseError.missingWebVTTHeader) {
            try SubtitleFileParser.parse("00:00.000 --> 00:01.000\nNo header.", format: .webVTT)
        }
        #expect(throws: SubtitleFileParser.ParseError.noCues) {
            try SubtitleFileParser.parse("", format: .srt)
        }
        #expect(throws: SubtitleFileParser.ParseError.noCues) {
            try SubtitleFileParser.parse("WEBVTT\n\nNOTE only comments here\n", format: .webVTT)
        }
        #expect(SubtitleFileParser.Format(fileExtension: "SRT") == .srt)
        #expect(SubtitleFileParser.Format(fileExtension: "vtt") == .webVTT)
        #expect(SubtitleFileParser.Format(fileExtension: "mov") == nil)
    }
}

@Suite struct SubtitleCueSpecTests {
    private func build(_ cues: [SubtitleCue]) async throws -> [EditorViewModel.TextClipSpec] {
        try await CaptionSpecBuilder.build(
            cues: cues, fps: 30, canvasWidth: 1920, canvasHeight: 1080,
            style: .caption, center: CGPoint(x: 0.5, y: 0.9)
        )
    }

    @Test func convertsCueSecondsToFramesInOneGroupClampingSubFrameCues() async throws {
        let specs = try await build([
            SubtitleCue(text: "one", startSeconds: 1.0, endSeconds: 2.5),
            SubtitleCue(text: "blip", startSeconds: 3.0, endSeconds: 3.01),
        ])
        #expect(specs.map(\.startFrame) == [30, 90])
        #expect(specs.map(\.durationFrames) == [45, 1])
        #expect(specs.allSatisfy { $0.transform != nil })
        let groupId = try #require(specs.first?.captionGroupId)
        #expect(specs.allSatisfy { $0.captionGroupId == groupId })
    }

    @Test func resolvesOverlapsWithoutClosingGaps() async throws {
        let specs = try await build([
            SubtitleCue(text: "overlapping", startSeconds: 0, endSeconds: 1.0),
            SubtitleCue(text: "next", startSeconds: 0.9, endSeconds: 2.0),
            SubtitleCue(text: "after gap", startSeconds: 2.2, endSeconds: 3.0),
        ])
        #expect(specs.map(\.startFrame) == [0, 27, 66])
        #expect(specs.map(\.durationFrames) == [27, 33, 24])
    }
}
