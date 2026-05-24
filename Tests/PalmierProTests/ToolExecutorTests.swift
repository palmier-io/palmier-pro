import Foundation
import Testing
@testable import PalmierPro

/// Holds both editor and executor strongly so the executor's weak ref to the editor
/// remains valid for the duration of the test.
@MainActor
final class ToolHarness {
    let editor: EditorViewModel
    let executor: ToolExecutor

    init(timeline: Timeline = Fixtures.timeline()) {
        let editor = EditorViewModel()
        editor.timeline = timeline
        self.editor = editor
        self.executor = ToolExecutor(editor: editor)
    }

    /// Run a tool by name and decode the .ok text payload as JSON.
    func runOK(_ name: String, args: [String: Any] = [:]) async throws -> Any {
        let result = await executor.execute(name: name, args: args)
        #expect(result.isError == false, "tool \(name) returned error: \(Self.textOf(result))")
        guard case let .text(s) = result.content.first else {
            Issue.record("expected text content for tool \(name)")
            return [:]
        }
        return try JSONSerialization.jsonObject(with: Data(s.utf8))
    }

    func runRaw(_ name: String, args: [String: Any] = [:]) async -> ToolResult {
        await executor.execute(name: name, args: args)
    }

    static func textOf(_ result: ToolResult) -> String {
        if case let .text(s) = result.content.first { return s }
        return "(non-text)"
    }

    /// Inject a stub MediaAsset into the editor so handlers that look up assets by id can find it.
    /// hasAudio defaults to false to avoid placeClip's implicit linked-audio-track creation —
    /// tests that need the linking behavior should pass hasAudio: true explicitly.
    @discardableResult
    func addAsset(
        id: String = UUID().uuidString,
        type: ClipType = .video,
        duration: Double = 5,
        hasAudio: Bool = false
    ) -> MediaAsset {
        let asset = MediaAsset(
            id: id,
            url: URL(fileURLWithPath: "/tmp/test-\(id).mov"),
            type: type,
            name: "stub-\(id)",
            duration: duration
        )
        asset.hasAudio = hasAudio
        editor.mediaAssets.append(asset)
        return asset
    }
}

@Suite("ToolExecutor — smoke")
@MainActor
struct ToolExecutorSmokeTests {

    @Test func unknownToolReturnsError() async {
        let h = ToolHarness()
        let result = await h.runRaw("nonexistent_tool")
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Unknown tool"))
    }

    @Test func getTimelineReturnsParseableJSON() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("get_timeline") as? [String: Any]
        #expect(json?["fps"] as? Int == 30)
        #expect(json?["tracks"] is [Any])
        #expect(json?["currentFrame"] is Int)
        #expect(json?["canGenerate"] is Bool)
    }
}

@Suite("ToolExecutor — read-only handlers")
@MainActor
struct ToolExecutorReadOnlyTests {

    // MARK: - get_timeline

    @Test func getTimelineReflectsCurrentTracksAndFrame() async throws {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1", clips: [Fixtures.clip(start: 0, duration: 50)]),
            Fixtures.audioTrack(label: "A1", clips: [Fixtures.clip(start: 0, duration: 100)]),
        ])
        let h = ToolHarness(timeline: timeline)
        h.editor.currentFrame = 42

        let json = try await h.runOK("get_timeline") as? [String: Any]
        let tracks = json?["tracks"] as? [[String: Any]]
        #expect(tracks?.count == 2)
        #expect(tracks?[0]["label"] as? String == "V1")
        #expect(tracks?[1]["label"] as? String == "A1")
        #expect(json?["currentFrame"] as? Int == 42)
    }

    @Test func getTimelineExposesCanGenerateFromAccountService() async throws {
        // AccountService.shared starts unpaid in test environment.
        let h = ToolHarness()
        let json = try await h.runOK("get_timeline") as? [String: Any]
        // We don't assert the value (depends on env), only that the key is present and Bool.
        #expect(json?["canGenerate"] is Bool)
    }

    // MARK: - get_media

    @Test func getMediaOnEmptyManifestReturnsEmptyEntries() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("get_media") as? [String: Any]
        let entries = json?["entries"] as? [Any]
        #expect(entries?.isEmpty == true)
    }

    // MARK: - list_folders

    @Test func listFoldersOnEmptyProjectReturnsEmptyArray() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("list_folders") as? [String: Any]
        let folders = json?["folders"] as? [Any]
        #expect(folders?.isEmpty == true)
    }

    @Test func listFoldersReportsExistingFolders() async throws {
        let h = ToolHarness()
        let id1 = h.editor.createFolder(name: "Refs", in: nil)
        _ = h.editor.createFolder(name: "Sub", in: id1)

        let json = try await h.runOK("list_folders") as? [String: Any]
        let folders = json?["folders"] as? [[String: Any]]
        #expect(folders?.count == 2)
        let names = folders?.compactMap { $0["name"] as? String }.sorted() ?? []
        #expect(names == ["Refs", "Sub"])
        // Child must carry parentFolderId; root must not.
        let sub = folders?.first { $0["name"] as? String == "Sub" }
        #expect(sub?["parentFolderId"] as? String == id1)
        let root = folders?.first { $0["name"] as? String == "Refs" }
        #expect(root?["parentFolderId"] == nil)
    }

    // MARK: - list_models

    /// ModelCatalog populates from Convex over the network — empty in tests. These verify
    /// shape and filter contract regardless of whether the catalog has any entries.

    @Test func listModelsReturnsWrappedShape() async throws {
        let h = ToolHarness()
        let body = try await h.runOK("list_models") as? [String: Any]
        #expect(body?["models"] is [Any])
        #expect(body?["loaded"] is Bool)
    }

    @Test func listModelsReportsCatalogNotLoadedInTestEnvironment() async throws {
        // No Convex connection → catalog stays unloaded. Agents must use this to disambiguate
        // empty results from "catalog not synced yet".
        let h = ToolHarness()
        let body = try await h.runOK("list_models") as? [String: Any]
        #expect(body?["loaded"] as? Bool == false)
    }

    @Test func listModelsFilterIsRespectedForAllEntries() async throws {
        let h = ToolHarness()
        let body = try await h.runOK("list_models", args: ["type": "image"]) as? [String: Any]
        let models = body?["models"] as? [[String: Any]]
        for m in models ?? [] {
            #expect(m["type"] as? String == "image")
        }
    }
}

@Suite("ToolExecutor — track handlers")
@MainActor
struct ToolExecutorTrackTests {

    @Test func addTrackCreatesVideoTrack() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("add_track", args: ["type": "video", "label": "MyVideo"])
        #expect(result.isError == false)
        #expect(h.editor.timeline.tracks.contains { $0.label == "MyVideo" && $0.type == .video })
    }

    @Test func addTrackUsesDefaultLabelWhenOmitted() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("add_track", args: ["type": "audio"])
        #expect(result.isError == false)
        let audioTrack = h.editor.timeline.tracks.first { $0.type == .audio }
        #expect(audioTrack != nil)
        #expect(audioTrack?.label.isEmpty == false)
    }

    @Test func addTrackRejectsInvalidType() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("add_track", args: ["type": "subtitle"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("invalid"))
    }

    @Test func addTrackRequiresTypeArg() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("add_track", args: [:])
        #expect(result.isError)
    }

    @Test func removeTrackDropsTheNamedTrack() async throws {
        let h = ToolHarness()
        _ = await h.runRaw("add_track", args: ["type": "video", "label": "Temp"])
        let trackId = h.editor.timeline.tracks.first { $0.label == "Temp" }!.id

        let result = await h.runRaw("remove_track", args: ["trackId": trackId])
        #expect(result.isError == false)
        #expect(h.editor.timeline.tracks.contains { $0.id == trackId } == false)
    }

    @Test func removeTrackRejectsMissingId() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("remove_track", args: ["trackId": "does-not-exist"])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("not found"))
    }
}

@Suite("ToolExecutor — clip handlers")
@MainActor
struct ToolExecutorClipTests {

    /// Build a harness with one video track and one video asset ready to place.
    private func setupWithVideoTrack() async -> (ToolHarness, MediaAsset) {
        let h = ToolHarness()
        _ = await h.runRaw("add_track", args: ["type": "video"])
        let asset = h.addAsset(type: .video)
        return (h, asset)
    }

    // MARK: - add_clips

    @Test func addClipsPlacesClipOnTrack() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let result = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 60,
            ]]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let clips = h.editor.timeline.tracks[0].clips
        #expect(clips.count == 1)
        #expect(clips[0].startFrame == 0)
        #expect(clips[0].durationFrames == 60)
        #expect(clips[0].mediaRef == asset.id)
    }

    @Test func addClipsRejectsOutOfRangeTrackIndex() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let result = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 99,
                "startFrame": 0,
                "durationFrames": 30,
            ]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("out of range"))
    }

    @Test func addClipsRejectsMissingMediaRef() async throws {
        let (h, _) = await setupWithVideoTrack()
        let result = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": "no-such-asset",
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 30,
            ]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("not found"))
    }

    @Test func addClipsRejectsIncompatibleAssetForTrack() async throws {
        // Audio asset onto a video track.
        let h = ToolHarness()
        _ = await h.runRaw("add_track", args: ["type": "video"])
        let audio = h.addAsset(type: .audio)
        let result = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": audio.id,
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 30,
            ]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not compatible"))
    }

    @Test func addClipsRejectsZeroDuration() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let result = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 0,
            ]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("durationFrames"))
    }

    @Test func addClipsRejectsEmptyEntries() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("add_clips", args: ["entries": []])
        #expect(result.isError)
    }

    // MARK: - remove_clips

    @Test func removeClipsDropsClipsByIds() async throws {
        let (h, asset) = await setupWithVideoTrack()
        // Two clips so the track survives the implicit pruneEmptyTracks pass.
        _ = await h.runRaw("add_clips", args: [
            "entries": [
                ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "durationFrames": 30],
                ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 60, "durationFrames": 30],
            ]
        ])
        let clipId = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }[0].id

        let result = await h.runRaw("remove_clips", args: ["clipIds": [clipId]])
        #expect(result.isError == false)
        #expect(h.editor.timeline.tracks[0].clips.count == 1)
        #expect(h.editor.timeline.tracks[0].clips[0].startFrame == 60)
    }

    @Test func removeClipsPrunesTrackWhenLastClipGoes() async throws {
        // Companion to the above: removing the only clip on a track also removes the track.
        // Pinning down this side-effect so anyone changing prune behavior has to update the test.
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "durationFrames": 30]]
        ])
        let clipId = h.editor.timeline.tracks[0].clips[0].id

        let result = await h.runRaw("remove_clips", args: ["clipIds": [clipId]])
        #expect(result.isError == false)
        #expect(h.editor.timeline.tracks.isEmpty, "empty track should be pruned after last clip removed")
    }

    @Test func removeClipsMessageMentionsPrunedTracks() async throws {
        // Without this, an LLM agent's trackIndex mental model silently desyncs after a remove.
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "durationFrames": 30]]
        ])
        let clipId = h.editor.timeline.tracks[0].clips[0].id

        let result = await h.runRaw("remove_clips", args: ["clipIds": [clipId]])
        let message = ToolHarness.textOf(result)
        #expect(message.contains("Pruned"), "expected prune note, got: \(message)")
        #expect(message.contains("re-read"), "expected hint to re-read timeline, got: \(message)")
    }

    @Test func removeClipsMessageOmitsPruneNoteWhenNothingPruned() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [
                ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "durationFrames": 30],
                ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 60, "durationFrames": 30],
            ]
        ])
        let clipId = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }[0].id

        let result = await h.runRaw("remove_clips", args: ["clipIds": [clipId]])
        let message = ToolHarness.textOf(result)
        #expect(!message.contains("Pruned"), "no tracks were pruned but message claims they were: \(message)")
    }

    @Test func removeClipsRejectsMissingIds() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("remove_clips", args: ["clipIds": ["does-not-exist"]])
        #expect(result.isError)
    }

    // MARK: - split_clip

    @Test func splitClipDividesAtFrame() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 60,
            ]]
        ])
        let clipId = h.editor.timeline.tracks[0].clips[0].id

        let result = await h.runRaw("split_clip", args: ["clipId": clipId, "atFrame": 30])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let clips = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.count == 2)
        #expect(clips[0].startFrame == 0 && clips[0].durationFrames == 30)
        #expect(clips[1].startFrame == 30 && clips[1].durationFrames == 30)
    }

    @Test func splitClipRejectsFrameOutsideClipRange() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 60,
            ]]
        ])
        let clipId = h.editor.timeline.tracks[0].clips[0].id

        // Split at endFrame should fail (must be strictly inside).
        let result = await h.runRaw("split_clip", args: ["clipId": clipId, "atFrame": 60])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("outside"))
    }

    // MARK: - move_clip

    @Test func moveClipChangesTrackAndStartFrame() async throws {
        let (h, asset) = await setupWithVideoTrack()
        // Add a second video track so we have somewhere to move to.
        _ = await h.runRaw("add_track", args: ["type": "video"])
        // Capture destination track id BEFORE the move; index can shift if the source track
        // empties and gets pruned away.
        let destTrackId = h.editor.timeline.tracks[1].id
        _ = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 60,
            ]]
        ])
        let clipId = h.editor.timeline.tracks[0].clips[0].id

        let result = await h.runRaw("move_clip", args: [
            "clipId": clipId,
            "toTrack": 1,
            "toFrame": 100,
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        // Find the moved clip by id. Track index may have shifted after pruning.
        let loc = h.editor.findClip(id: clipId)
        #expect(loc != nil, "clip should still exist after move")
        if let loc {
            let destTrack = h.editor.timeline.tracks[loc.trackIndex]
            #expect(destTrack.id == destTrackId, "clip should be on the requested destination track")
            #expect(destTrack.clips[loc.clipIndex].startFrame == 100)
        }
    }

    @Test func moveClipRejectsMissingClip() async throws {
        let h = ToolHarness()
        _ = await h.runRaw("add_track", args: ["type": "video"])
        let result = await h.runRaw("move_clip", args: [
            "clipId": "ghost",
            "toTrack": 0,
            "toFrame": 0,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not found"))
    }

    // MARK: - update_clips

    /// Add a video clip and return its id, for tests that need an existing clip.
    private func addedClip(in h: ToolHarness, asset: MediaAsset, duration: Int = 60) async -> String {
        _ = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": duration,
            ]]
        ])
        return h.editor.timeline.tracks[0].clips[0].id
    }

    @Test func updateClipsChangesSpeedAndVolume() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)

        let result = await h.runRaw("update_clips", args: [
            "updates": [["clipId": clipId, "speed": 2.0, "volume": 0.5]]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let clip = h.editor.timeline.tracks[0].clips[0]
        #expect(clip.speed == 2.0)
        #expect(clip.volume == 0.5)
    }

    @Test func updateClipsChangesOpacity() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)

        _ = await h.runRaw("update_clips", args: [
            "updates": [["clipId": clipId, "opacity": 0.25]]
        ])
        #expect(h.editor.timeline.tracks[0].clips[0].opacity == 0.25)
    }

    @Test func updateClipsRejectsUnknownKey() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("update_clips", args: [
            "updates": [["clipId": clipId, "unknownField": 99]]
        ])
        #expect(result.isError)
    }

    @Test func updateClipsRejectsMissingClipId() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("update_clips", args: [
            "updates": [["clipId": "ghost", "speed": 2.0]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("not found"))
    }

    @Test func updateClipsRejectsTextOnlyFieldsOnVideoClip() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("update_clips", args: [
            "updates": [["clipId": clipId, "fontSize": 48]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("text clips"))
    }

    @Test func updateClipsRejectsEmptyUpdatesArray() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("update_clips", args: ["updates": []])
        #expect(result.isError)
    }
}

@Suite("ToolExecutor — text and folder handlers")
@MainActor
struct ToolExecutorTextFolderTests {

    // MARK: - add_texts

    @Test func addTextsCreatesNewTrackWhenIndexOmitted() async throws {
        let h = ToolHarness()
        let initialTrackCount = h.editor.timeline.tracks.count
        let result = await h.runRaw("add_texts", args: [
            "entries": [[
                "startFrame": 0,
                "durationFrames": 90,
                "content": "Hello",
            ]]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        // A new video track was auto-created for text since no trackIndex was given.
        #expect(h.editor.timeline.tracks.count == initialTrackCount + 1)
        let textClips = h.editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .text }
        #expect(textClips.count == 1)
        #expect(textClips[0].textContent == "Hello")
        #expect(textClips[0].durationFrames == 90)
    }

    @Test func addTextsPlacesOnExplicitTrack() async throws {
        let h = ToolHarness()
        _ = await h.runRaw("add_track", args: ["type": "video"])
        let result = await h.runRaw("add_texts", args: [
            "entries": [[
                "trackIndex": 0,
                "startFrame": 30,
                "durationFrames": 60,
                "content": "Caption",
                "fontSize": 48,
            ]]
        ])
        #expect(result.isError == false)
        let clip = h.editor.timeline.tracks[0].clips[0]
        #expect(clip.textContent == "Caption")
        #expect(clip.textStyle?.fontSize == 48)
    }

    @Test func addTextsRejectsAudioTargetTrack() async throws {
        let h = ToolHarness()
        _ = await h.runRaw("add_track", args: ["type": "audio"])
        let result = await h.runRaw("add_texts", args: [
            "entries": [[
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 30,
                "content": "Subtitle",
            ]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("audio"))
    }

    @Test func addTextsRejectsMixedTrackIndexUsage() async throws {
        let h = ToolHarness()
        _ = await h.runRaw("add_track", args: ["type": "video"])
        let result = await h.runRaw("add_texts", args: [
            "entries": [
                ["trackIndex": 0, "startFrame": 0, "durationFrames": 30, "content": "A"],
                ["startFrame": 60, "durationFrames": 30, "content": "B"], // missing trackIndex
            ]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Mixed trackIndex"))
    }

    @Test func addTextsRejectsZeroDuration() async throws {
        let h = ToolHarness()
        _ = await h.runRaw("add_track", args: ["type": "video"])
        let result = await h.runRaw("add_texts", args: [
            "entries": [[
                "trackIndex": 0,
                "startFrame": 0,
                "durationFrames": 0,
                "content": "x",
            ]]
        ])
        #expect(result.isError)
    }

    // MARK: - create_folder + move_to_folder

    @Test func createFolderAddsRootLevelFolder() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("create_folder", args: ["name": "Refs"]) as? [String: Any]
        let id = json?["id"] as? String
        #expect(id != nil)
        #expect(h.editor.folders.contains { $0.id == id && $0.parentFolderId == nil })
    }

    @Test func createFolderNestsInsideParent() async throws {
        let h = ToolHarness()
        let parentId = h.editor.createFolder(name: "Parent", in: nil)
        let json = try await h.runOK("create_folder", args: [
            "name": "Child",
            "parentFolderId": parentId,
        ]) as? [String: Any]
        let childId = json?["id"] as? String
        let child = h.editor.folders.first { $0.id == childId }
        #expect(child?.parentFolderId == parentId)
    }

    @Test func createFolderRejectsMissingParent() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("create_folder", args: [
            "name": "Orphan",
            "parentFolderId": "no-such-folder",
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not found"))
    }

    @Test func moveToFolderRelocatesAssets() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video)
        let folderId = h.editor.createFolder(name: "Refs", in: nil)

        let result = await h.runRaw("move_to_folder", args: [
            "assetIds": [asset.id],
            "folderId": folderId,
        ])
        #expect(result.isError == false)
        // mediaAssets always carries folderId; manifest only if there's an entry for this asset.
        let updated = h.editor.mediaAssets.first { $0.id == asset.id }
        #expect(updated?.folderId == folderId)
    }

    @Test func moveToFolderRejectsUnknownAsset() async throws {
        let h = ToolHarness()
        let folderId = h.editor.createFolder(name: "Refs", in: nil)
        let result = await h.runRaw("move_to_folder", args: [
            "assetIds": ["ghost"],
            "folderId": folderId,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not found"))
    }

    @Test func moveToFolderRejectsEmptyAssetIds() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("move_to_folder", args: ["assetIds": []])
        #expect(result.isError)
    }
}
