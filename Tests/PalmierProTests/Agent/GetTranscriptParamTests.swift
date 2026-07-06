import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("get_transcript — param tolerance")
struct GetTranscriptParamTests {
    // Empty timeline so the call returns an empty transcript without needing audio —
    // we only care that key validation accepts (or rejects) the params.

    @Test func toleratesWordTimestampsFromInspectMediaHabit() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let result = await h.runRaw("get_transcript", args: ["wordTimestamps": true])
        #expect(result.isError == false) // words are the default; the key must not hard-fail
    }

    @Test func stillRejectsGenuinelyUnknownKeys() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let result = await h.runRaw("get_transcript", args: ["bogusKey": true])
        #expect(result.isError == true)
    }

    @Test func segmentsGranularityDeclaresSegmentFormat() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        let json = try await h.runOK("get_transcript", args: ["granularity": "segments"]) as? [String: Any]
        #expect(json?["segmentFormat"] as? [String] == ["firstWordIndex", "text", "start", "end"])
        #expect(json?["wordFormat"] == nil)
        #expect(await h.runRaw("get_transcript", args: ["granularity": "sentences"]).isError)
    }

    @Test func usesNestedWordShape() async throws {
        // Words nest under clips with a hoisted wordFormat; there is no top-level words array.
        let h = ToolHarness(timeline: Fixtures.timeline())
        let json = try await h.runOK("get_transcript") as? [String: Any]
        #expect(json?["wordFormat"] as? [String] == ["index", "text", "start"])
        #expect(json?["clips"] is [[String: Any]])
        #expect(json?["words"] == nil)
    }

    @Test func wordRowsSpeakerRunsAndSegments() async throws {
        func w(_ i: Int, _ text: String, _ start: Int, _ end: Int, _ speaker: String?) -> TimelineWord {
            TimelineWord(index: i, clipId: "c1", trackIndex: 0, clipStartFrame: 0, clipEndFrame: 300,
                         text: text, startFrame: start, endFrame: end, speaker: speaker)
        }
        let transcript = TimelineTranscript(
            context: .init(provider: .local, preferredLocale: nil),
            words: [
                w(0, "Hello", 0, 10, "S1"), w(1, "there.", 10, 20, "S1"),
                w(2, "Hi", 60, 70, "S2"), w(3, "back.", 70, 80, "S2"),
                w(4, "Great", 90, 100, "S1"),
            ],
            skipped: []
        )

        let words = transcript.responsePayload(fps: 30, clipId: nil, startFrame: nil, endFrame: nil, maxWords: 100)
        #expect(words["wordFormat"] as? [String] == ["index", "text", "start"])
        let rows = ((words["clips"] as? [[String: Any]])?.first?["words"]) as? [[Any]]
        #expect(rows?.count == 5)
        #expect(rows?.first?.count == 3) // no per-word end, no speaker column
        // Speakers arrive as run-length turns keyed by word index.
        let runs = words["speakers"] as? [[Any]]
        #expect(runs?.count == 3)
        #expect(runs?[1][0] as? Int == 2)
        #expect(runs?[1][1] as? String == "S2")

        let segs = transcript.responsePayload(fps: 30, clipId: nil, startFrame: nil, endFrame: nil, maxWords: 100, segments: true)
        let segRows = ((segs["clips"] as? [[String: Any]])?.first?["segments"]) as? [[Any]]
        // Sentence end, speaker change, and trailing run each flush: 3 segments.
        #expect(segRows?.count == 3)
        #expect(segRows?.first?[1] as? String == "Hello there.")
        #expect(segRows?.first?[0] as? Int == 0)   // firstWordIndex handle
        #expect(segRows?.first?[3] as? Int == 20)  // segment end retains real end frames
    }
}
