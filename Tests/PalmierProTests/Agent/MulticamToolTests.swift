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

    /// Tool payloads shorten ids; direct VM calls need the full id from the editor.
    private func createGroup(_ h: ToolHarness) async throws -> String {
        let r = try #require(await h.runOK("manage_multicam", args: createArgs()) as? [String: Any])
        let created = try #require(r["created"] as? [String: Any])
        let short = try #require(created["groupId"] as? String)
        return try #require(h.editor.multicamGroups.first { $0.id.hasPrefix(short) }?.id)
    }

    @Test func createReportsGroupAndClips() async throws {
        let h = harness()
        let outer = try #require(await h.runOK("manage_multicam", args: createArgs()) as? [String: Any])
        let r = try #require(outer["created"] as? [String: Any])
        #expect(r["groupId"] != nil)
        let members = try #require(r["members"] as? [[String: Any]])
        #expect(members.count == 3)
        #expect(members.allSatisfy { ($0["pinned"] as? Bool) == true })
        #expect((r["clipIds"] as? [String])?.count == 2)

        // The group's clips are plain clips in get_timeline; groups list in the payload.
        let tl = try #require(await h.runOK("get_timeline") as? [String: Any])
        let groups = try #require(tl["multicamGroups"] as? [[String: Any]])
        #expect(groups.first?["angles"] as? [String] == ["cam-a", "cam-b"])
        // Unlinked clips: program video and mic audio each visible on their track.
        let tracks = try #require(tl["tracks"] as? [[String: Any]])
        let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
        #expect(clips.count == 2)
    }

    @Test func changeCamCutsInPlace() async throws {
        let h = harness()
        let groupId = try await createGroup(h)

        let r = try #require(await h.runOK("change_cam", args: [
            "groupId": groupId,
            "entries": [["range": [600, 1200], "angle": "cam-b"]],
        ]) as? [String: Any])
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

    @Test func resolveByClipIdWorks() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        let clipId = h.editor.multicamClips(of: groupId)[0].clip.id
        let read = try #require(await h.runOK("get_multicam", args: ["clipId": clipId]) as? [String: Any])
        let shortId = try #require(read["groupId"] as? String)
        #expect(groupId.hasPrefix(shortId))
    }

    // MARK: - Lifecycle verbs

    @Test func ungroupLeavesOrdinaryClips() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        let clipCount = h.editor.multicamClips(of: groupId).count
        _ = try #require(await h.runOK("manage_multicam", args: ["ungroup": ["groupId": groupId]]) as? [String: Any])
        #expect(h.editor.multicamClips(of: groupId).isEmpty)
        #expect(h.editor.multicamGroup(id: groupId) == nil)
        // Same clips, just unstamped.
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == clipCount)
    }

    // MARK: - Guardrails through the tools

    @Test func moveRefusedOnGroupClips() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        let clipId = h.editor.multicamClips(of: groupId)[0].clip.id
        let r = await h.runRaw("move_clips", args: ["moves": [["clipId": clipId, "toFrame": 999]]])
        #expect(r.isError == true)
        #expect(ToolHarness.textOf(r).contains("sync"))
    }

    @Test func moveWholeGroupAllowed() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        let clips = h.editor.multicamClips(of: groupId).map(\.clip)
        let moves = clips.map { ["clipId": $0.id, "toFrame": $0.startFrame + 300] as [String: Any] }
        let r = await h.runRaw("move_clips", args: ["moves": moves])
        #expect(r.isError == false)
        let starts = h.editor.multicamClips(of: groupId).map(\.clip.startFrame).sorted()
        #expect(starts == clips.map { $0.startFrame + 300 }.sorted())
    }

    @Test func timingFieldsRefusedOnGroupClips() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        let clipId = h.editor.multicamClips(of: groupId)[0].clip.id

        let timing = await h.runRaw("set_clip_properties", args: ["clipIds": [clipId], "trimStartFrame": 30])
        #expect(timing.isError == true)
        let speed = await h.runRaw("set_clip_properties", args: ["clipIds": [clipId], "speed": 2.0])
        #expect(speed.isError == true)
        let property = await h.runRaw("set_clip_properties", args: ["clipIds": [clipId], "opacity": 0.5])
        #expect(property.isError == false)
    }

    @Test func syncClipsRefusedOnGroupClips() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        h.editor.addClips(assets: [h.editor.mediaAssets.first { $0.id == "camA" }!], trackIndex: 0, startFrame: 5000)
        let stray = h.editor.timeline.tracks.flatMap(\.clips).first { $0.multicamGroupId == nil && $0.mediaType == .video }!
        let target = h.editor.multicamClips(of: groupId)[0].clip.id
        let r = await h.runRaw("sync_clips", args: ["referenceClipId": stray.id, "targetClipIds": [target]])
        #expect(r.isError == true)
        #expect(ToolHarness.textOf(r).contains("already aligned"))
    }

    @Test func groupTrackRemovalAndUnlockRefused() async throws {
        let h = harness()
        let groupId = try await createGroup(h)
        let trackIdx = h.editor.multicamClips(of: groupId)[0].trackIndex

        let remove = await h.runRaw("manage_tracks", args: ["remove": [trackIdx]])
        #expect(remove.isError == true)
        let unlock = await h.runRaw("manage_tracks", args: ["set": [["index": trackIdx, "syncLocked": false]]])
        #expect(unlock.isError == true)
        // Mute/hide stay free.
        let mute = await h.runRaw("manage_tracks", args: ["set": [["index": trackIdx, "muted": true]]])
        #expect(mute.isError == false)
    }
}
