import Foundation
import Testing
@testable import PalmierPro

@Suite("multicam tools")
@MainActor
struct MulticamToolTests {

    private func harness() -> ToolHarness {
        let h = ToolHarness()
        h.addAsset(id: "camA", type: .video, duration: 120, hasAudio: true)
        h.addAsset(id: "camB", type: .video, duration: 110, hasAudio: true)
        h.addAsset(id: "mic1", type: .audio, duration: 130)
        return h
    }

    // Stub assets have no readable audio, so members pin offsets — the no-correlation path.
    private func createArgs() -> [String: Any] {
        ["create": [
            "name": "Podcast",
            "members": [
                ["mediaRef": "camA", "kind": "angle", "angleLabel": "cam-a", "offsetSeconds": 0],
                ["mediaRef": "camB", "kind": "angle", "angleLabel": "cam-b", "offsetSeconds": 5],
                ["mediaRef": "mic1", "kind": "mic", "angleLabel": "mic-1", "offsetSeconds": 2],
            ],
            "master": "mic-1",
            "startFrame": 0,
        ] as [String: Any]]
    }

    private func createGroup(_ h: ToolHarness) async throws -> String {
        let r = try #require(await h.runOK("manage_multicam", args: createArgs()) as? [String: Any])
        let created = try #require(r["created"] as? [String: Any])
        return try #require(created["groupId"] as? String)
    }

    @Test func createReportsGroupAndCarriers() async throws {
        let h = harness()
        let outer = try #require(await h.runOK("manage_multicam", args: createArgs()) as? [String: Any])
        let r = try #require(outer["created"] as? [String: Any])
        #expect(r["groupId"] != nil)
        let members = try #require(r["members"] as? [[String: Any]])
        #expect(members.count == 3)
        #expect(members.allSatisfy { ($0["pinned"] as? Bool) == true })
        #expect((r["carrierClipIds"] as? [String])?.count == 2)

        // The group is one folded clip in get_timeline and annotated in the timelines list.
        let tl = try #require(await h.runOK("get_timeline") as? [String: Any])
        let tracks = try #require(tl["tracks"] as? [[String: Any]])
        let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
        #expect(clips.count == 1)
        #expect(clips[0]["audio"] != nil)

        let media = try #require(await h.runOK("get_media") as? [String: Any])
        let timelines = try #require(media["timelines"] as? [[String: Any]])
        let group = timelines.first { $0["multicam"] != nil }
        #expect((group?["multicam"] as? [String: Any])?["angles"] as? [String] == ["cam-a", "cam-b"])
    }

    @Test func changeCamSwitchesWithoutParentDelta() async throws {
        let h = harness()
        let groupId = try await createGroup(h)

        let r = try #require(await h.runOK("change_cam", args: [
            "groupId": groupId,
            "entries": [["range": [600, 1200], "angle": "cam-b"]],
        ]) as? [String: Any])
        #expect(r["clips"] == nil && r["shifted"] == nil && r["removedClipIds"] == nil)
        let program = try #require(r["program"] as? [[Any]])
        #expect(program.contains { ($0[0] as? String) == "cam-b" && ($0[1] as? Int) == 600 && ($0[2] as? Int) == 1200 })

        let read = try #require(await h.runOK("get_multicam", args: ["groupId": groupId]) as? [String: Any])
        let rows = try #require(read["program"] as? [[Any]])
        #expect(rows.map { $0[0] as? String } == ["cam-a", "cam-b", "cam-a"])
    }

    @Test func changeCamValidatesEntries() async throws {
        let h = harness()
        let groupId = try await createGroup(h)

        let both = await h.runRaw("change_cam", args: [
            "groupId": groupId,
            "entries": [["range": [0, 60], "angle": "cam-a", "layout": "grid_2x2"]],
        ])
        #expect(both.isError == true)

        let unknownAngle = await h.runRaw("change_cam", args: [
            "groupId": groupId,
            "entries": [["range": [0, 60], "angle": "cam-z"]],
        ])
        #expect(unknownAngle.isError == true)
        #expect(ToolHarness.textOf(unknownAngle).contains("cam-a"))
    }

    @Test func groupAllowsActivationButRefusesDuplication() async throws {
        let h = harness()
        let groupId = try await createGroup(h)

        let enter = try #require(await h.runOK("set_active_timeline", args: ["timelineId": groupId]) as? [String: Any])
        #expect((enter["note"] as? String)?.contains("multicam") == true)
        let duplicate = await h.runRaw("create_timeline", args: ["from": groupId])
        #expect(duplicate.isError == true)
    }

    @Test func structureToolsRefuseLoudlyInsideTheGroup() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        _ = try #require(await h.runOK("set_active_timeline", args: ["timelineId": groupId]) as? [String: Any])
        let programClipId = h.editor.timeline.tracks[0].clips[0].id

        let refused: [(String, [String: Any])] = [
            ("add_clips", ["entries": [["mediaRef": "camA", "startFrame": 0]]]),
            ("move_clips", ["moves": [["clipId": programClipId, "toFrame": 99]]]),
            ("add_texts", ["entries": [["text": "hi", "startFrame": 0, "durationFrames": 30]]]),
            ("manage_tracks", ["reorder": [["index": 0, "to": 1]]]),
            ("sync_clips", ["referenceClipId": programClipId, "targetClipIds": ["x"]]),
        ]
        for (tool, args) in refused {
            let r = await h.runRaw(tool, args: args)
            #expect(r.isError == true, "\(tool) should refuse inside a group")
            #expect(ToolHarness.textOf(r).contains("multicam"), "\(tool) should explain the group lock")
        }
        let create = await h.runRaw("manage_multicam", args: createArgs())
        #expect(create.isError == true)

        // Properties and track flags stay free.
        let props = await h.runRaw("set_clip_properties", args: ["clipIds": [programClipId], "opacity": 0.5])
        #expect(props.isError == false)
        let flags = await h.runRaw("manage_tracks", args: ["set": [["index": 1, "muted": true]]])
        #expect(flags.isError == false)
    }

    @Test func changeCamAndReadWorkInsideTheGroup() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        _ = try #require(await h.runOK("set_active_timeline", args: ["timelineId": groupId]) as? [String: Any])

        // Ranges are the group's own frames while inside.
        let r = try #require(await h.runOK("change_cam", args: [
            "groupId": groupId,
            "entries": [["range": [600, 1200], "angle": "cam-b"]],
        ]) as? [String: Any])
        let program = try #require(r["program"] as? [[Any]])
        #expect(program.contains { ($0[0] as? String) == "cam-b" && ($0[1] as? Int) == 600 && ($0[2] as? Int) == 1200 })

        let read = try #require(await h.runOK("get_multicam", args: ["groupId": groupId]) as? [String: Any])
        #expect((read["note"] as? String)?.contains("inside") == true)
        let rows = try #require(read["program"] as? [[Any]])
        #expect(rows.map { $0[0] as? String } == ["cam-a", "cam-b", "cam-a"])
    }

    @Test func deletingMemberAssetKeepsChildTracks() async throws {
        let h = harness()
        _ = try await createGroup(h)
        let child = h.editor.timelines.first { $0.isMulticam }!

        _ = h.editor.removeClipsReferencingAssets(["mic1"])
        let after = h.editor.timelines.first { $0.isMulticam }!
        #expect(after.tracks.count == child.tracks.count)
        #expect(after.tracks.contains { $0.id == after.multicam!.programTrackId })
    }

    @Test func createRejectsBadKinds() async throws {
        let h = harness()
        let r = await h.runRaw("manage_multicam", args: [
            "create": [
                "members": [
                    ["mediaRef": "mic1", "kind": "angle"],
                    ["mediaRef": "camA", "kind": "mic"],
                ],
            ] as [String: Any],
        ])
        #expect(r.isError == true)
        #expect(ToolHarness.textOf(r).contains("video"))
    }

    @Test func bakeRefusesClipsOutsideTheGroup() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        // A plain clip on the parent is not a member of the group.
        h.editor.addClips(assets: [h.editor.mediaAssets.first { $0.id == "camA" }!], trackIndex: 0, startFrame: 4000)
        let stray = h.editor.timeline.tracks.flatMap(\.clips).first { $0.mediaRef == "camA" }!
        let r = await h.runRaw("manage_multicam", args: ["bake": ["groupId": groupId, "clipId": stray.id]])
        #expect(r.isError == true)
    }

    @Test func timingFieldsRefusedInsideGroup() async throws {
        let h = harness()
        _ = try await createGroup(h)
        let childId = h.editor.timelines.first { $0.isMulticam }!.id
        h.editor.activateTimeline(childId)
        let programClip = h.editor.timeline.tracks[0].clips[0]

        let timing = await h.runRaw("set_clip_properties", args: ["clipIds": [programClip.id], "trimStartFrame": 30])
        #expect(timing.isError == true)
        let property = await h.runRaw("set_clip_properties", args: ["clipIds": [programClip.id], "opacity": 0.5])
        #expect(property.isError == false)
    }

    @Test func bakeDecomposesToPlainClips() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        _ = try #require(await h.runOK("change_cam", args: [
            "groupId": groupId,
            "entries": [["range": [600, 1200], "angle": "cam-b"]],
        ]) as? [String: Any])

        let outer = try #require(await h.runOK("manage_multicam", args: [
            "bake": ["groupId": groupId],
        ]) as? [String: Any])
        let baked = try #require(outer["baked"] as? [String: Any])
        // One visual carrier; its linked audio partner decomposes with it.
        #expect(baked["bakedClips"] as? Int == 1)

        // Angle cuts are now real clips on the parent; no carriers remain.
        let clips = h.editor.timeline.tracks.flatMap(\.clips)
        #expect(clips.allSatisfy { $0.sourceClipType != .sequence })
        #expect(clips.contains { $0.mediaRef == "camB" })
        #expect(clips.contains { $0.mediaRef == "mic1" })
    }

    @Test func switchChildSegmentInsideGlassRoom() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        _ = try #require(await h.runOK("change_cam", args: [
            "groupId": groupId,
            "entries": [["range": [600, 1200], "angle": "cam-b"]],
        ]) as? [String: Any])

        // Tool results shorten ids; direct VM calls need the full one.
        let childId = h.editor.timelines.first { $0.isMulticam }!.id
        h.editor.activateTimeline(childId)
        let source = h.editor.timeline.multicam!
        let programIdx = h.editor.timeline.tracks.firstIndex { $0.id == source.programTrackId }!

        // Frame 900 falls inside the cam-b segment (600..<1200); works from any clip's menu.
        h.editor.switchChildSegment(atFrame: 900, to: "cam-a")
        let program = h.editor.timeline.tracks[programIdx].clips
        #expect(program.count == 1)
        #expect(program[0].mediaRef == "camA")
    }

    @Test func manualLayoutInsideGlassRoom() async throws {
        let h = harness()
        _ = try await createGroup(h)
        let childId = h.editor.timelines.first { $0.isMulticam }!.id
        h.editor.activateTimeline(childId)
        let source = h.editor.timeline.multicam!

        // Two cameras in a 2×2 grid: two cells filled, two blank; clamped to cam-b (150..<3450).
        h.editor.applyChildLayout(atFrame: 300, layout: .grid2x2)
        let updated = h.editor.timeline.multicam!
        #expect(updated.overlayTrackIds.count == 1)
        let overlay = h.editor.timeline.tracks.first { $0.id == updated.overlayTrackIds[0] }!
        #expect(overlay.clips.count == 1)
        #expect(overlay.clips[0].mediaRef == "camB")
        #expect(overlay.clips[0].startFrame == 150 && overlay.clips[0].endFrame == 3450)
        // Program (cam-a was showing) keeps the first slot: top-left quadrant.
        let programIdx = h.editor.timeline.tracks.firstIndex { $0.id == source.programTrackId }!
        let slotted = h.editor.timeline.tracks[programIdx].clips.first { 300 >= $0.startFrame && 300 < $0.endFrame }!
        #expect(abs(slotted.transform.width - 0.5) < 1e-9 && abs(slotted.transform.height - 0.5) < 1e-9)

        // Full Frame exits the layout: overlays cleared, seams heal back to one clip.
        h.editor.applyChildLayout(atFrame: 300, layout: .full)
        #expect(h.editor.timeline.tracks.first { $0.id == updated.overlayTrackIds[0] }!.clips.isEmpty)
        #expect(h.editor.timeline.tracks[programIdx].clips.count == 1)
    }
}
