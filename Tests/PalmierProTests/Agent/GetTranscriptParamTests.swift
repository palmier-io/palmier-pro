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

    @Test func usesNestedWordShape() async throws {
        // Words nest under clips with a hoisted wordFormat; there is no top-level words array.
        let h = ToolHarness(timeline: Fixtures.timeline())
        let json = try await h.runOK("get_transcript") as? [String: Any]
        #expect(json?["wordFormat"] as? [String] == ["text", "start", "end"])
        #expect(json?["clips"] is [[String: Any]])
        #expect(json?["words"] == nil)
    }
}
