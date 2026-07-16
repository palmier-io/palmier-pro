import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("undo tool")
struct UndoToolTests {
    private func harness() -> (ToolHarness, UndoManager) {
        let track = Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)])
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [track]))
        let um = UndoManager()
        h.editor.undo.attach(um)
        return (h, um)
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

    @Test func addFirstImportedClipIncludesSettingsInAgentTransaction() async throws {
        let h = ToolHarness()
        let um = UndoManager()
        h.editor.undo.attach(um)
        let originalTimeline = h.editor.timeline
        let asset = h.addAsset(type: .video)
        asset.sourceWidth = 1280
        asset.sourceHeight = 720

        let result = await h.runRaw("add_clips", args: ["entries": [[
            "mediaRef": asset.id,
            "startFrame": 0,
            "endFrame": 30,
        ]]])

        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 1)
        #expect(h.editor.timeline.width == 1280)
        #expect(h.editor.timeline.height == 720)
        #expect(um.groupingLevel == 0)

        let undo = await h.runRaw("undo")
        #expect(!undo.isError, "\(ToolHarness.textOf(undo))")
        #expect(h.editor.timeline == originalTimeline)
    }

    @Test func insertFirstImportedClipIncludesSettingsInAgentTransaction() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let um = UndoManager()
        h.editor.undo.attach(um)
        let originalTimeline = h.editor.timeline
        let asset = h.addAsset(type: .video)
        asset.sourceWidth = 1280
        asset.sourceHeight = 720

        let result = await h.runRaw("insert_clips", args: [
            "trackIndex": 0,
            "atFrame": 0,
            "entries": [["mediaRef": asset.id, "durationFrames": 30]],
        ])

        #expect(!result.isError, "\(ToolHarness.textOf(result))")
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 1)
        #expect(um.groupingLevel == 0)

        let undo = await h.runRaw("undo")
        #expect(!undo.isError, "\(ToolHarness.textOf(undo))")
        #expect(h.editor.timeline == originalTimeline)
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

    @Test func undoUsesSharedHistoryAcrossExecutors() async throws {
        let (h, um) = harness()
        let other = ToolExecutor(editor: h.editor)

        _ = await h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "volume": 0.25])
        _ = await other.execute(
            name: "set_clip_properties",
            args: ["clipIds": ["c1"], "volume": 0.5]
        )

        #expect(!(await h.runRaw("undo")).isError)
        #expect(h.editor.timeline.tracks[0].clips[0].volume == 0.25)
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

    @Test func reportsNothingToUndoAfterRead() async throws {
        let (h, um) = harness()
        _ = um
        _ = await h.runRaw("get_timeline") // a read is not an edit
        #expect(await h.runRaw("undo").isError == true)
    }

    @Test func undoRevertsLatestUserEdit() async throws {
        let (h, um) = harness()
        _ = um
        _ = await h.runRaw("ripple_delete_ranges", args: ["clipId": "c1", "ranges": [[40, 50]]])
        let beforeUserEdit = h.editor.timeline
        h.editor.withTimelineSwap(actionName: "Trim Clip") {
            h.editor.timeline.tracks[0].clips[0].durationFrames = 20
        }
        let result = await h.runRaw("undo")
        #expect(result.isError == false)
        #expect(h.editor.timeline == beforeUserEdit)
    }
}
