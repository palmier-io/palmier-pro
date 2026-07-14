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

    @Test func undoKeepsNewTimelineWhenAutomaticEventGroupStaysOpen() async throws {
        let (h, um) = harness()
        um.registerUndo(withTarget: h.editor) { _ in }
        um.setActionName("Earlier Tool")
        #expect(um.groupingLevel == 1)
        let sourceTimelineId = h.editor.activeTimelineId

        _ = await h.runRaw("create_timeline", args: ["from": sourceTimelineId])
        let createdTimelineId = h.editor.activeTimelineId
        let createdClipId = h.editor.timeline.tracks[0].clips[0].id
        _ = await h.runRaw("set_clip_properties", args: [
            "clipIds": [createdClipId],
            "volume": 0.25,
        ])

        let result = await h.runRaw("undo")

        #expect(result.isError == false)
        #expect(h.editor.timelines.count == 2)
        #expect(h.editor.activeTimelineId == createdTimelineId)
        #expect(h.editor.timeline.tracks[0].clips[0].volume == 1.0)
    }

    @Test func automaticGroupingRemainsUsableAfterAgentEdit() async throws {
        let (h, um) = harness()
        um.registerUndo(withTarget: h.editor) { _ in }
        #expect(um.groupingLevel == 1)

        _ = await h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "volume": 0.5])
        #expect(um.groupingLevel == 0)

        // A later automatic event group must still open and register cleanly (#320).
        um.registerUndo(withTarget: h.editor) { _ in }
        #expect(um.groupingLevel == 1)
        _ = await h.runRaw("ripple_delete_ranges", args: ["clipId": "c1", "ranges": [[40, 50]]])
        #expect(um.canUndo)
    }

    @Test func concurrentAgentEditsRemainSeparateUndoSteps() async throws {
        let (h, um) = harness()
        _ = um

        async let first = h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "volume": 0.25])
        async let second = h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "volume": 0.5])
        _ = await (first, second)

        _ = await h.runRaw("undo")
        #expect(h.editor.timeline.tracks[0].clips[0].volume != 1.0)
        _ = await h.runRaw("undo")
        #expect(h.editor.timeline.tracks[0].clips[0].volume == 1.0)
    }

    @Test func refusesWhileUserUndoGroupIsOpen() async throws {
        let (h, um) = harness()
        um.groupsByEvent = false
        um.beginUndoGrouping()

        let result = await h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "volume": 0.5])

        #expect(result.isError)
        #expect(h.editor.timeline.tracks[0].clips[0].volume == 1.0)
        #expect(um.groupingLevel == 1)
        um.endUndoGrouping()
        um.groupsByEvent = true
    }

    @Test func sessionsCannotUndoIdenticallyNamedTransactions() async throws {
        let (h, um) = harness()
        let other = ToolExecutor(editor: h.editor)

        _ = await h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "volume": 0.25])
        _ = await other.execute(
            name: "set_clip_properties",
            args: ["clipIds": ["c1"], "volume": 0.5]
        )

        #expect(await h.runRaw("undo").isError)
        #expect(!(await other.execute(name: "undo", args: [:])).isError)
        #expect(!(await h.runRaw("undo")).isError)
        #expect(h.editor.timeline.tracks[0].clips[0].volume == 1.0)
        _ = um
    }

    @Test func nativeUndoConsumesAgentTransaction() async throws {
        let (h, um) = harness()
        _ = await h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "volume": 0.5])

        um.undo()

        #expect(h.editor.timeline.tracks[0].clips[0].volume == 1.0)
        #expect(await h.runRaw("undo").isError)
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
