import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("apply_transition tool")
struct ApplyTransitionTests {

    private func harness(clips: [Clip]) -> ToolHarness {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)]))
        h.editor.undo.attach(UndoManager())
        return h
    }

    @Test func applyDissolveOverlapsAdjacentClips() async throws {
        let h = harness(clips: [
            Fixtures.clip(id: "out", start: 0, duration: 90),
            Fixtures.clip(id: "inn", start: 90, duration: 90),
        ])

        let json = try await h.runOK("apply_transition", args: [
            "transitions": [[
                "outgoingClipId": "out",
                "incomingClipId": "inn",
                "type": "dissolve",
                "durationFrames": 18,
            ]],
        ]) as? [String: Any]

        let applied = (json?["applied"] as? [[String: Any]])?.first
        #expect(applied?["type"] as? String == "dissolve")
        #expect(applied?["durationFrames"] as? Int == 18)

        let inn = h.editor.clipFor(id: "inn")
        #expect(inn?.startFrame == 72)
        #expect(inn?.transition?.type == "dissolve")
        #expect(inn?.transition?.durationFrames == 18)

        let timeline = try await h.runOK("get_timeline") as? [String: Any]
        let tracks = timeline?["tracks"] as? [[String: Any]]
        let clips = tracks?.first?["clips"] as? [[String: Any]]
        let shaped = clips?.first { ($0["id"] as? String) == "inn" }
        let transition = shaped?["transition"] as? [String: Any]
        #expect(transition?["type"] as? String == "dissolve")
        #expect(transition?["durationFrames"] as? Int == 18)
    }

    @Test func removeRestoresHardCut() async throws {
        let h = harness(clips: [
            Fixtures.clip(id: "out", start: 0, duration: 90),
            Fixtures.clip(id: "inn", start: 90, duration: 90),
        ])
        _ = try await h.runOK("apply_transition", args: [
            "transitions": [[
                "outgoingClipId": "out",
                "incomingClipId": "inn",
                "type": "push.right",
                "durationFrames": 12,
            ]],
        ])

        _ = try await h.runOK("apply_transition", args: [
            "incomingClipIds": ["inn"],
        ])

        #expect(h.editor.clipFor(id: "inn")?.transition == nil)
        #expect(h.editor.clipFor(id: "inn")?.startFrame == 90)
    }

    @Test func rejectsUnknownTypeAndGap() async throws {
        let h = harness(clips: [
            Fixtures.clip(id: "out", start: 0, duration: 60),
            Fixtures.clip(id: "inn", start: 80, duration: 60),
        ])

        let unknown = await h.runRaw("apply_transition", args: [
            "transitions": [[
                "outgoingClipId": "out",
                "incomingClipId": "inn",
                "type": "spin.3d",
                "durationFrames": 10,
            ]],
        ])
        #expect(unknown.isError)
        #expect(ToolHarness.textOf(unknown).contains("Unknown transition"))

        let gap = await h.runRaw("apply_transition", args: [
            "transitions": [[
                "outgoingClipId": "out",
                "incomingClipId": "inn",
                "type": "dissolve",
                "durationFrames": 10,
            ]],
        ])
        #expect(gap.isError)
        #expect(ToolHarness.textOf(gap).contains("adjacent"))
    }

    @Test func toolIsDiscoverable() {
        #expect(ToolDefinitions.all.contains { $0.name == .applyTransition })
        #expect(ToolName(rawValue: "apply_transition") == .applyTransition)
    }
}
