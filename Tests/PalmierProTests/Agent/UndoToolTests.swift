import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("undo tool")
struct UndoToolTests {
    /// Returns the harness and the UndoManager (editor.undoManager is weak — the caller must
    /// hold the manager alive for the test).
    private func harness() -> (ToolHarness, UndoManager) {
        let track = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [track]))
        let um = UndoManager()
        h.editor.undoManager = um
        return (h, um)
    }

    @Test func undoRevertsAgentRippleDelete() async throws {
        let (h, um) = harness()
        _ = um
        _ = await h.runRaw("ripple_delete_ranges", args: ["clipId": "c1", "ranges": [[40, 50]]])
        #expect(h.editor.timeline.tracks[0].clips.count == 2) // the cut split c1 into two

        let result = await h.runRaw("undo")
        #expect(result.isError == false)
        #expect(h.editor.timeline.tracks[0].clips.count == 1)
        #expect(h.editor.timeline.tracks[0].clips[0].durationFrames == 100) // back to the original
    }

    @Test func undoRevertsOnlyTheMostRecentToolCall() async throws {
        let (h, um) = harness()
        _ = um
        _ = await h.runRaw("split_clips", args: ["trackIndex": 0, "frames": [30]])
        #expect(h.editor.timeline.tracks[0].clips.count == 2)
        _ = await h.runRaw("ripple_delete_ranges", args: ["trackIndex": 0, "ranges": [[40, 50]]])

        let result = await h.runRaw("undo")
        #expect(result.isError == false)
        // Only the ripple reverts — the split from the earlier call must survive.
        #expect(h.editor.timeline.tracks[0].clips.count == 2)
        #expect(h.editor.timeline.tracks[0].clips.map(\.durationFrames) == [30, 70])
    }

    @Test func refusesWhenAssistantHasNotEdited() async throws {
        let (h, um) = harness()
        _ = um
        _ = await h.runRaw("get_timeline") // a read is not an edit
        #expect(await h.runRaw("undo").isError == true)
    }

    @Test func refusesSecondUndoWithNothingLeft() async throws {
        let (h, um) = harness()
        _ = um
        _ = await h.runRaw("ripple_delete_ranges", args: ["clipId": "c1", "ranges": [[40, 50]]])
        _ = await h.runRaw("undo")
        #expect(await h.runRaw("undo").isError == true)
    }

    @Test func refusesWhenLatestEditIsNotTheAssistants() async throws {
        let (h, um) = harness()
        _ = um
        _ = await h.runRaw("ripple_delete_ranges", args: ["clipId": "c1", "ranges": [[40, 50]]])
        // The user makes a manual edit on top of the assistant's.
        h.editor.withTimelineSwap(actionName: "Trim Clip") {
            h.editor.timeline.tracks[0].clips[0].durationFrames = 20
        }
        let result = await h.runRaw("undo")
        #expect(result.isError == true) // won't revert the user's edit
    }
}
