import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — remove_silence")
@MainActor
struct RemoveSilenceTests {
    private func harness() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "vid1", start: 0, duration: 100)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "txt1", mediaType: .text, start: 0, duration: 100)]),
        ]))
    }

    @Test func rejectsMissingClipId() async throws {
        let h = harness()
        let result = await h.runRaw("remove_silence", args: [:])
        #expect(result.isError == true)
    }

    @Test func rejectsUnknownClipId() async throws {
        let h = harness()
        let result = await h.runRaw("remove_silence", args: ["clipId": "nope"])
        #expect(result.isError == true)
    }

    @Test func rejectsTextClip() async throws {
        let h = harness()
        let result = await h.runRaw("remove_silence", args: ["clipId": "txt1"])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("not an audio or video clip"))
    }

    @Test func rejectsPositiveThresholdDb() async throws {
        let h = harness()
        let result = await h.runRaw("remove_silence", args: ["clipId": "vid1", "thresholdDb": 6])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).contains("dBFS"))
    }

    @Test func rejectsNonPositiveMinDuration() async throws {
        let h = harness()
        let result = await h.runRaw("remove_silence", args: ["clipId": "vid1", "minSilenceDuration": 0])
        #expect(result.isError == true)
    }

    @Test func rejectsUnknownKeys() async throws {
        let h = harness()
        let result = await h.runRaw("remove_silence", args: ["clipId": "vid1", "bogus": 1])
        #expect(result.isError == true)
    }

    @Test func toolIsRegisteredInDefinitions() {
        #expect(ToolDefinitions.all.contains { $0.name == .removeSilence })
    }
}
