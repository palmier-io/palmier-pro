import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — timelines")
@MainActor
struct TimelineToolsTests {

    @Test func getTimelineListsTimelinesOnlyWhenSeveralExist() async throws {
        let h = ToolHarness()
        let single = try await h.runOK("get_timeline") as? [String: Any]
        #expect(single?["timelines"] == nil)

        var second = Fixtures.timeline()
        second.name = "B-Roll"
        h.editor.timelines.append(second)
        let multi = try await h.runOK("get_timeline") as? [String: Any]
        let listed = multi?["timelines"] as? [[String: Any]]
        #expect(listed?.count == 2)
        #expect(listed?.first?["active"] as? Bool == true)
        #expect(listed?.last?["name"] as? String == "B-Roll")
        #expect(multi?["viewState"] == nil)
    }

    @Test func createTimelineSwitchesAndInheritsSettings() async throws {
        let h = ToolHarness()
        h.editor.timeline.fps = 60
        let result = await h.runRaw("create_timeline", args: ["name": "Intro"])
        #expect(!result.isError)
        #expect(ToolHarness.textOf(result).contains("Intro"))
        #expect(h.editor.timeline.name == "Intro")
        #expect(h.editor.timeline.fps == 60)
        #expect(h.editor.timelines.count == 2)
    }

    @Test func setActiveTimelineSwitchesByShortPrefix() async throws {
        let h = ToolHarness()
        let firstId = h.editor.activeTimelineId
        var second = Fixtures.timeline()
        second.name = "Cutdown"
        h.editor.timelines.append(second)

        let result = await h.runRaw("set_active_timeline", args: ["timelineId": String(second.id.prefix(8))])
        #expect(!result.isError)
        #expect(h.editor.activeTimelineId == second.id)
        #expect(h.editor.activeTimelineId != firstId)
        // Switching registers no undo — the agent undo stack must stay clean.
        let undo = await h.runRaw("undo")
        #expect(undo.isError)
    }

    @Test func createTimelineFromDuplicatesRenamesAndSwitches() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "orig", start: 0, duration: 30)])
        ]))
        let sourceId = h.editor.activeTimelineId

        let result = await h.runRaw("create_timeline", args: ["from": sourceId, "name": "Vertical Cut"])
        #expect(!result.isError)
        #expect(h.editor.timelines.count == 2)
        #expect(h.editor.timeline.name == "Vertical Cut")
        #expect(h.editor.activeTimelineId != sourceId)
        // Fresh clip ids; content copied.
        #expect(h.editor.timeline.tracks[0].clips.count == 1)
        #expect(h.editor.timeline.tracks[0].clips[0].id != "orig")
        #expect(h.editor.timeline.tracks[0].clips[0].durationFrames == 30)
    }

    @Test func setActiveTimelineRejectsUnknownId() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("set_active_timeline", args: ["timelineId": "ffffffff"])
        #expect(result.isError)
    }

    @Test func addClipsNestsTimelineWithLinkedAudio() async throws {
        let h = ToolHarness()
        let child = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 60)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(mediaType: .audio, start: 0, duration: 60)])
        ])
        h.editor.timelines.append(child)

        let result = await h.runRaw("add_clips", args: ["entries": [
            ["mediaRef": child.id, "startFrame": 30]
        ]])
        #expect(!result.isError, "\(ToolHarness.textOf(result))")

        let video = h.editor.timeline.tracks.first { $0.type == .video }!.clips[0]
        let audio = h.editor.timeline.tracks.first { $0.type == .audio }!.clips[0]
        #expect(video.mediaType == .sequence && video.sourceClipType == .sequence)
        #expect(video.mediaRef == child.id)
        #expect(video.startFrame == 30 && video.durationFrames == 60)
        #expect(audio.sourceClipType == .sequence)
        #expect(audio.linkGroupId == video.linkGroupId && video.linkGroupId != nil)
    }

    @Test func addClipsRejectsNestCyclesAndEmptyTimelines() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])
        ]))
        // Self-nesting rejected.
        let selfNest = await h.runRaw("add_clips", args: ["entries": [
            ["mediaRef": h.editor.activeTimelineId, "startFrame": 0]
        ]])
        #expect(selfNest.isError)

        // Empty child rejected.
        let empty = Fixtures.timeline()
        h.editor.timelines.append(empty)
        let emptyNest = await h.runRaw("add_clips", args: ["entries": [
            ["mediaRef": empty.id, "startFrame": 0]
        ]])
        #expect(emptyNest.isError)
    }

    @Test func organizeMediaAcceptsTimelines() async throws {
        let h = ToolHarness()
        let child = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)])])
        h.editor.timelines.append(child)

        let rename = await h.runRaw("organize_media", args: [
            "renames": [["item": child.id, "name": "Selects"]],
        ])
        #expect(!rename.isError)
        #expect(h.editor.timeline(for: child.id)?.name == "Selects")

        let move = await h.runRaw("organize_media", args: [
            "moves": [["items": [child.id], "into": "Cuts"]],
        ])
        #expect(!move.isError)
        #expect(h.editor.timeline(for: child.id)?.folderId != nil)

        let delete = await h.runRaw("organize_media", args: ["deletes": [child.id]])
        #expect(!delete.isError)
        #expect(h.editor.timelines.count == 1)

        // The last timeline is protected.
        let last = await h.runRaw("organize_media", args: ["deletes": [h.editor.activeTimelineId]])
        #expect(last.isError)
        #expect(h.editor.timelines.count == 1)
    }
}
