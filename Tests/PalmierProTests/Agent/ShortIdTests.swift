import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("short id round-trip")
struct ShortIdTests {
    private func uuid(_ first8: String) -> String {
        // A valid uppercase UUID whose first 8 chars are caller-controlled (for collision tests).
        "\(first8)-0000-0000-0000-000000000000"
    }

    @Test func emitsShortPrefixForFullUuid() async throws {
        let id = uuid("ABCD1234")
        let track = Fixtures.videoTrack(clips: [Fixtures.clip(id: id, start: 0, duration: 100)])
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [track]))

        let text = ToolHarness.textOf(await h.runRaw("get_timeline"))
        #expect(text.contains("ABCD1234"))
        #expect(!text.contains(id), "full uuid should not appear in output")
    }

    @Test func acceptsPrefixBackAsArgument() async throws {
        let id = uuid("ABCD1234")
        let track = Fixtures.videoTrack(clips: [Fixtures.clip(id: id, start: 0, duration: 100)])
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [track]))

        // The agent sends back the 8-char prefix it was given.
        let result = await h.runRaw("ripple_delete_ranges", args: ["clipId": "ABCD1234", "ranges": [[40, 50]]])
        #expect(result.isError == false)
        #expect(h.editor.timeline.tracks[0].clips.count == 2)
    }

    @Test func fullUuidStillResolves() async throws {
        let id = uuid("ABCD1234")
        let track = Fixtures.videoTrack(clips: [Fixtures.clip(id: id, start: 0, duration: 100)])
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [track]))

        let result = await h.runRaw("ripple_delete_ranges", args: ["clipId": id, "ranges": [[40, 50]]])
        #expect(result.isError == false)
    }

    @Test func ambiguousPrefixIsRejected() async throws {
        // Two ids share the first 8 chars, so the shared prefix can't pick one — resolve must refuse.
        let a = uuid("ABCD1234")
        let b = "ABCD1234-FFFF-0000-0000-000000000000"
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: a, start: 0, duration: 100),
            Fixtures.clip(id: b, start: 200, duration: 100),
        ])
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [track]))

        let result = await h.runRaw("ripple_delete_ranges", args: ["clipId": "ABCD1234", "ranges": [[40, 50]]])
        #expect(result.isError == true)
        #expect(ToolHarness.textOf(result).localizedCaseInsensitiveContains("ambiguous"))
    }

    @Test func prefixExtendsPastSharedRun() {
        let a = uuid("ABCD1234")
        let b = "ABCD1234-FFFF-0000-0000-000000000000"
        let map = ToolExecutor.shortIdMap([a, b])
        // They share 8 chars, so each prefix must extend past the shared run to stay distinct.
        #expect(map[a] != map[b])
        #expect(map[a]!.count > 8)
    }

    @Test func unsharedIdGetsFloorLength() {
        let id = uuid("ABCD1234")
        #expect(ToolExecutor.shortIdMap([id, uuid("EEEE9999")])[id] == "ABCD1234")
    }
}
