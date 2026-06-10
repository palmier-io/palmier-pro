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

    @Test func getTimelineRoundsFloatingPointNumbersToThreeDecimalPlaces() async throws {
        var clip = Fixtures.clip(
            mediaType: .video,
            start: 0,
            duration: 90,
            speed: 1.23456789,
            volume: 0.987654321
        )
        clip.opacity = 0.123456789
        clip.transform = Transform(
            centerX: 0.123456789,
            centerY: 0.987654321,
            width: 0.3333333333,
            height: 0.6666666666
        )
        clip.crop = Crop(
            left: 0.1111111111,
            top: 0.2222222222,
            right: 0.3333333333,
            bottom: 0.4444444444
        )
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.123456789),
            Keyframe(frame: 30, value: 0.987654321),
        ])
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1", clips: [clip]),
        ])
        let h = ToolHarness(timeline: timeline)

        let result = await h.runRaw("get_timeline")
        guard case let .text(raw) = result.content.first else {
            Issue.record("expected text content for get_timeline")
            return
        }
        #expect(raw.range(of: #"-?\d+\.\d{4,}"#, options: .regularExpression) == nil)

        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let tracks = json?["tracks"] as? [[String: Any]]
        let outClip = (tracks?.first?["clips"] as? [[String: Any]])?.first
        #expect(outClip?["speed"] as? Double == 1.235)
        #expect(outClip?["volume"] as? Double == 0.988)
        #expect(outClip?["opacity"] as? Double == 0.123)
    }

    @Test func getTimelineOmitsDefaultValuedFields() async throws {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1", clips: [Fixtures.clip(id: "c1", start: 0, duration: 50)]),
        ])
        let h = ToolHarness(timeline: timeline)

        let json = try await h.runOK("get_timeline") as? [String: Any]
        let track = Self.firstTrack(json)
        #expect(track?["muted"] == nil)
        #expect(track?["hidden"] == nil)
        #expect(track?["syncLocked"] == nil)
        #expect(track?["label"] as? String == "V1")

        let clip = (track?["clips"] as? [[String: Any]])?.first
        #expect(clip?["id"] as? String == "c1")
        #expect(clip?["mediaRef"] as? String == "media-1")
        #expect(clip?["startFrame"] as? Int == 0)
        #expect(clip?["durationFrames"] as? Int == 50)
        for defaulted in [
            "mediaType", "sourceClipType", "speed", "volume", "opacity",
            "trimStartFrame", "trimEndFrame", "fadeInFrames", "fadeOutFrames",
            "fadeInInterpolation", "fadeOutInterpolation", "transform", "crop",
        ] {
            #expect(clip?[defaulted] == nil, "expected default field '\(defaulted)' to be omitted")
        }
        #expect(json?["totalFrames"] as? Int == 50)
        #expect(json?["window"] == nil)
    }

    @Test func getTimelineCollapsesCaptionGroups() async throws {
        let texts = ["one", "two", "three"]
        let clips = texts.enumerated().map { i, text in
            Self.captionClip(id: "cap-\(i)", gid: "g1", start: i * 30, duration: 30, text: text, width: 0.2 + Double(i) * 0.1)
        }
        let video = Fixtures.clip(id: "v1", start: 0, duration: 90)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1", clips: [video] + clips),
        ])
        let h = ToolHarness(timeline: timeline)

        let json = try await h.runOK("get_timeline") as? [String: Any]
        let loose = Self.firstTrack(json)?["clips"] as? [[String: Any]]
        #expect(loose?.count == 1)
        #expect(loose?.first?["id"] as? String == "v1")

        let group = Self.firstCaptionGroup(json)
        #expect(group?["captionGroupId"] as? String == "g1")
        #expect(group?["clipCount"] as? Int == 3)
        #expect(group?["frameRange"] as? [Int] == [0, 90])

        let shared = group?["shared"] as? [String: Any]
        #expect(shared?["mediaType"] as? String == "text")
        #expect((shared?["textStyle"] as? [String: Any])?["fontName"] as? String == "Avenir")
        let sharedTransform = shared?["transform"] as? [String: Any]
        #expect(sharedTransform?["centerY"] as? Double == 0.85)
        #expect(sharedTransform?["width"] == nil)
        #expect(sharedTransform?["height"] == nil)

        let rows = group?["clips"] as? [[Any]]
        #expect(rows?.count == 3)
        #expect(rows?.first?[0] as? String == "cap-0")
        #expect(rows?.first?[1] as? Int == 0)
        #expect(rows?.first?[2] as? Int == 30)
        #expect(rows?.first?[3] as? String == "one")
    }

    @Test func getTimelineListsDeviantCaptionClipsIndividually() async throws {
        var clips = (0..<3).map { i in
            Self.captionClip(id: "cap-\(i)", gid: "g1", start: i * 30, duration: 30, text: "t\(i)")
        }
        clips[1].textStyle?.color = TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1)
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1", clips: clips),
        ])
        let h = ToolHarness(timeline: timeline)

        let json = try await h.runOK("get_timeline") as? [String: Any]
        let group = Self.firstCaptionGroup(json)
        #expect(group?["clipCount"] as? Int == 2)
        #expect((group?["clips"] as? [[Any]])?.count == 2)

        let loose = Self.firstTrack(json)?["clips"] as? [[String: Any]]
        #expect(loose?.count == 1)
        #expect(loose?.first?["id"] as? String == "cap-1")
        #expect(loose?.first?["captionGroupId"] as? String == "g1")
    }

    @Test func getTimelineWindowsClipsToRequestedRange() async throws {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1", clips: [
                Fixtures.clip(id: "a", start: 0, duration: 50),
                Fixtures.clip(id: "b", start: 100, duration: 50),
                Fixtures.clip(id: "c", start: 200, duration: 50),
            ]),
        ])
        let h = ToolHarness(timeline: timeline)

        let json = try await h.runOK("get_timeline", args: ["startFrame": 90, "endFrame": 160]) as? [String: Any]
        let track = Self.firstTrack(json)
        let clips = track?["clips"] as? [[String: Any]]
        #expect(clips?.count == 1)
        #expect(clips?.first?["id"] as? String == "b")
        #expect(track?["totalClips"] as? Int == 3)
        #expect(json?["window"] as? [Int] == [90, 160])
        #expect(json?["totalFrames"] as? Int == 250)
    }

    @Test func getTimelineCapsCaptionRowsAndNotesPaging() async throws {
        let clips = (0..<250).map { i in
            Self.captionClip(id: "cap-\(i)", gid: "g1", start: i * 30, duration: 30, text: "t\(i)")
        }
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1", clips: clips),
        ]))

        let json = try await h.runOK("get_timeline") as? [String: Any]
        let group = Self.firstCaptionGroup(json)
        #expect(group?["clipCount"] as? Int == 250)
        #expect((group?["clips"] as? [[Any]])?.count == 200)
        #expect((group?["clipsNote"] as? String)?.contains("250") == true)

        // Windowing pages past the cap.
        let paged = try await h.runOK("get_timeline", args: ["startFrame": 6000, "endFrame": 7500]) as? [String: Any]
        let pagedRows = Self.firstCaptionGroup(paged)?["clips"] as? [[Any]]
        #expect(pagedRows?.count == 50)
        #expect(pagedRows?.first?[0] as? String == "cap-200")
    }

    @Test func getTimelineIgnoresTrimsOnTextClipsWhenGrouping() async throws {
        var clips = (0..<3).map { i in
            Self.captionClip(id: "cap-\(i)", gid: "g1", start: i * 30, duration: 30, text: "t\(i)")
        }
        clips[0].trimEndFrame = 3
        clips[1].trimStartFrame = 5
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(label: "V1", clips: clips),
        ]))

        let json = try await h.runOK("get_timeline") as? [String: Any]
        #expect(Self.firstCaptionGroup(json)?["clipCount"] as? Int == 3)
        #expect((Self.firstTrack(json)?["clips"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func getTimelineRejectsInvalidWindow() async {
        let h = ToolHarness()
        let result = await h.runRaw("get_timeline", args: ["startFrame": 100, "endFrame": 50])
        #expect(result.isError)
    }

    private static func firstTrack(_ json: [String: Any]?) -> [String: Any]? {
        (json?["tracks"] as? [[String: Any]])?.first
    }

    private static func firstCaptionGroup(_ json: [String: Any]?) -> [String: Any]? {
        (firstTrack(json)?["captionGroups"] as? [[String: Any]])?.first
    }

    private static func captionClip(id: String, gid: String, start: Int, duration: Int, text: String, width: Double = 0.2) -> Clip {
        var c = Clip(
            mediaRef: "",
            mediaType: .text,
            sourceClipType: .text,
            startFrame: start,
            durationFrames: duration,
            transform: Transform(center: (0.5, 0.85), width: width, height: 0.1)
        )
        c.id = id
        c.textContent = text
        c.captionGroupId = gid
        var style = TextStyle()
        style.fontName = "Avenir"
        c.textStyle = style
        return c
    }

    // MARK: - get_media

    @Test func getMediaOnEmptyManifestReturnsEmptyEntries() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("get_media") as? [String: Any]
        let entries = json?["entries"] as? [Any]
        #expect(entries?.isEmpty == true)
    }

    @Test func getMediaRoundsFloatingPointNumbersToThreeDecimalPlaces() async throws {
        let h = ToolHarness()
        var input = GenerationInput(
            prompt: "Generate",
            model: "model-1",
            duration: 5,
            aspectRatio: "16:9"
        )
        input.createdAt = Date(timeIntervalSinceReferenceDate: 123.123456)
        h.editor.mediaManifest.entries = [
            MediaManifestEntry(
                id: "asset-1",
                name: "Clip",
                type: .video,
                source: .external(absolutePath: "/tmp/media.mov"),
                duration: 12.3456789,
                generationInput: input,
                sourceWidth: 1920,
                sourceHeight: 1080,
                sourceFPS: 29.97002997,
                hasAudio: true,
                folderId: nil,
                cachedRemoteURL: nil,
                cachedRemoteURLExpiresAt: nil
            ),
        ]

        let result = await h.runRaw("get_media")
        guard case let .text(raw) = result.content.first else {
            Issue.record("expected text content for get_media")
            return
        }
        #expect(raw.range(of: #"-?\d+\.\d{4,}"#, options: .regularExpression) == nil)

        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let entries = json?["entries"] as? [[String: Any]]
        let entry = entries?.first
        #expect(entry?["duration"] as? Double == 12.346)
        #expect(entry?["sourceFPS"] as? Double == 29.97)
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

@Suite("ToolExecutor — clip handlers")
@MainActor
struct ToolExecutorClipTests {

    /// Build a harness with one video track and one video asset ready to place.
    private func setupWithVideoTrack() async -> (ToolHarness, MediaAsset) {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
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
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
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

    @Test func addClipsAutoCreatesTrackWhenIndexOmitted() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video)
        let initialCount = h.editor.timeline.tracks.count
        let result = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "startFrame": 0,
                "durationFrames": 30,
            ]]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        #expect(h.editor.timeline.tracks.count == initialCount + 1)
        let createdTrack = h.editor.timeline.tracks.first { $0.type == .video }
        #expect(createdTrack?.clips.first?.mediaRef == asset.id)
    }

    @Test func addClipsSharesOneTrackForMultipleVisualEntriesWhenOmitted() async throws {
        let h = ToolHarness()
        let a = h.addAsset(type: .video)
        let b = h.addAsset(type: .image)
        let initialCount = h.editor.timeline.tracks.count
        let result = await h.runRaw("add_clips", args: [
            "entries": [
                ["mediaRef": a.id, "startFrame": 0, "durationFrames": 30],
                ["mediaRef": b.id, "startFrame": 60, "durationFrames": 30],
            ]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        // One shared video track was created.
        #expect(h.editor.timeline.tracks.count == initialCount + 1)
        let videoTracks = h.editor.timeline.tracks.filter { $0.type == .video }
        #expect(videoTracks.count == 1)
        #expect(videoTracks.first?.clips.count == 2)
    }

    @Test func addClipsCreatesSeparateTracksForVideoAndAudioWhenOmitted() async throws {
        let h = ToolHarness()
        let video = h.addAsset(type: .video)
        let audio = h.addAsset(type: .audio)
        let initial = h.editor.timeline.tracks.count
        let result = await h.runRaw("add_clips", args: [
            "entries": [
                ["mediaRef": video.id, "startFrame": 0, "durationFrames": 30],
                ["mediaRef": audio.id, "startFrame": 0, "durationFrames": 30],
            ]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        // Exactly one video + one audio track created.
        #expect(h.editor.timeline.tracks.count == initial + 2)
        let videoTracks = h.editor.timeline.tracks.filter { $0.type == .video }
        let audioTracks = h.editor.timeline.tracks.filter { $0.type == .audio }
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)
        // Each clip landed on a track of its matching type.
        #expect(videoTracks.first?.clips.first?.mediaRef == video.id)
        #expect(audioTracks.first?.clips.first?.mediaRef == audio.id)
    }

    /// Regression for the stale-shared-index bug: when audio entries are interleaved with video
    /// in an all-omit batch, inserting the video track must not strand earlier audio clips on
    /// the (now-shifted) wrong index.
    @Test func addClipsAudioBeforeVideoAllOmittedRoutesByType() async throws {
        let h = ToolHarness()
        let audio1 = h.addAsset(type: .audio)
        let video = h.addAsset(type: .video)
        let audio2 = h.addAsset(type: .audio)
        let result = await h.runRaw("add_clips", args: [
            "entries": [
                ["mediaRef": audio1.id, "startFrame": 0, "durationFrames": 30],
                ["mediaRef": video.id, "startFrame": 0, "durationFrames": 30],
                ["mediaRef": audio2.id, "startFrame": 60, "durationFrames": 30],
            ]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        // Two audio clips on one shared audio track; one video clip on one shared video track.
        let videoTracks = h.editor.timeline.tracks.filter { $0.type == .video }
        let audioTracks = h.editor.timeline.tracks.filter { $0.type == .audio }
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)
        #expect(videoTracks.first?.clips.count == 1)
        #expect(audioTracks.first?.clips.count == 2)
        // Confirm by-type routing: no audio mediaRef on the video track and vice versa.
        let audioRefs = audioTracks.first?.clips.map(\.mediaRef).sorted() ?? []
        #expect(audioRefs == [audio1.id, audio2.id].sorted())
        #expect(videoTracks.first?.clips.first?.mediaRef == video.id)
    }

    @Test func addClipsRejectsMixedTrackIndexUsage() async throws {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
        let a = h.addAsset(type: .video)
        let b = h.addAsset(type: .video)
        let result = await h.runRaw("add_clips", args: [
            "entries": [
                ["mediaRef": a.id, "trackIndex": 0, "startFrame": 0, "durationFrames": 30],
                ["mediaRef": b.id, "startFrame": 60, "durationFrames": 30], // omitted trackIndex
            ]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Mixed trackIndex"))
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

    // MARK: - move_clips

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

    @Test func moveClipsChangesTrackAndFrame() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
        let destTrackId = h.editor.timeline.tracks[1].id
        let clipId = await addedClip(in: h, asset: asset)

        let result = await h.runRaw("move_clips", args: [
            "moves": [["clipId": clipId, "toTrack": 1, "toFrame": 100]]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        if let loc = h.editor.findClip(id: clipId) {
            let destTrack = h.editor.timeline.tracks[loc.trackIndex]
            #expect(destTrack.id == destTrackId)
            #expect(destTrack.clips[loc.clipIndex].startFrame == 100)
        } else {
            Issue.record("clip disappeared after move")
        }
    }

    @Test func moveClipsRequiresAtLeastOneOfTrackOrFrame() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("move_clips", args: [
            "moves": [["clipId": clipId]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("toTrack"))
    }

    @Test func moveClipsRejectsIncompatibleTrack() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = h.editor.insertTrack(at: 0, type: .audio, label: "Audio")
        let clipId = await addedClip(in: h, asset: asset)
        let audioIdx = h.editor.timeline.tracks.firstIndex(where: { $0.type == .audio })!
        let result = await h.runRaw("move_clips", args: [
            "moves": [["clipId": clipId, "toTrack": audioIdx]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("incompatible"))
    }

    @Test func moveClipsRejectsMissingClipId() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("move_clips", args: [
            "moves": [["clipId": "ghost", "toFrame": 30]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("not found"))
    }

    @Test func moveClipsRejectsEmptyMovesArray() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("move_clips", args: ["moves": []])
        #expect(result.isError)
    }

    // MARK: - move_clips: linked-partner propagation

    /// Place a video-with-audio asset so placeClip auto-creates the linked audio track,
    /// then return the resulting (videoClipId, audioClipId).
    private func setupLinkedPair() async -> (ToolHarness, videoId: String, audioId: String) {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
        let asset = h.addAsset(type: .video, duration: 5, hasAudio: true)
        let ids = h.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60)
        return (h, ids[0], ids[1])
    }

    @Test func moveClipsFrameDeltaPropagatesToLinkedPartner() async throws {
        let (h, videoId, audioId) = await setupLinkedPair()
        let result = await h.runRaw("move_clips", args: [
            "moves": [["clipId": videoId, "toFrame": 60]]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        guard let videoLoc = h.editor.findClip(id: videoId),
              let audioLoc = h.editor.findClip(id: audioId) else {
            Issue.record("clips disappeared"); return
        }
        let videoClip = h.editor.timeline.tracks[videoLoc.trackIndex].clips[videoLoc.clipIndex]
        let audioClip = h.editor.timeline.tracks[audioLoc.trackIndex].clips[audioLoc.clipIndex]
        #expect(videoClip.startFrame == 60)
        #expect(audioClip.startFrame == 60, "linked audio should track the video's frame delta")
        #expect(ToolHarness.textOf(result).contains("linked"))
    }

    @Test func moveClipsTrackChangeDoesNotMoveLinkedPartner() async throws {
        let (h, videoId, audioId) = await setupLinkedPair()
        // Add a second video track so the video has somewhere to move to.
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video2")
        guard let audioLoc = h.editor.findClip(id: audioId) else { Issue.record("setup failed"); return }
        let audioTrackId = h.editor.timeline.tracks[audioLoc.trackIndex].id

        let result = await h.runRaw("move_clips", args: [
            "moves": [["clipId": videoId, "toTrack": 0, "toFrame": 120]]
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        guard let newAudioLoc = h.editor.findClip(id: audioId) else {
            Issue.record("audio partner disappeared"); return
        }
        let audioClip = h.editor.timeline.tracks[newAudioLoc.trackIndex].clips[newAudioLoc.clipIndex]
        #expect(h.editor.timeline.tracks[newAudioLoc.trackIndex].id == audioTrackId,
                "linked audio should stay on its own track when video moves track")
        #expect(audioClip.startFrame == 120, "linked audio should move by the same frame delta")
    }

    // MARK: - set_clip_properties

    @Test func setClipPropertiesChangesSpeedAndVolume() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId], "speed": 2.0, "volume": 0.5,
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let clip = h.editor.timeline.tracks[0].clips[0]
        #expect(clip.speed == 2.0)
        #expect(clip.volume == 0.5)
    }

    @Test func setClipPropertiesChangesOpacity() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        _ = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId], "opacity": 0.25,
        ])
        #expect(h.editor.timeline.tracks[0].clips[0].opacity == 0.25)
    }

    @Test func setClipPropertiesAppliesUniformlyToMultipleClips() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let id1 = await addedClip(in: h, asset: asset, duration: 30)
        // Place a second clip at a non-overlapping range on the same track.
        _ = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 60, "durationFrames": 30]]
        ])
        let id2 = h.editor.timeline.tracks[0].clips.first { $0.id != id1 }!.id
        _ = await h.runRaw("set_clip_properties", args: [
            "clipIds": [id1, id2], "volume": 0.4,
        ])
        for clip in h.editor.timeline.tracks[0].clips {
            #expect(clip.volume == 0.4, "all listed clips share the property value")
        }
    }

    @Test func setClipPropertiesRejectsUnknownKey() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId], "unknownField": 99,
        ])
        #expect(result.isError)
    }

    @Test func setClipPropertiesRejectsMissingClipId() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": ["ghost"], "speed": 2.0,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("not found"))
    }

    @Test func setClipPropertiesRejectsTextOnlyFieldsOnVideoClip() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId], "fontSize": 48,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("text"))
    }

    @Test func setClipPropertiesRejectsEmptyClipIds() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("set_clip_properties", args: ["clipIds": [], "speed": 2.0])
        #expect(result.isError)
    }

    @Test func setClipPropertiesRejectsNoProperties() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("set_clip_properties", args: ["clipIds": [clipId]])
        #expect(result.isError)
    }

    @Test func setClipPropertiesDurationAndSpeedPropagateToLinkedPartner() async throws {
        let (h, videoId, audioId) = await setupLinkedPair()
        _ = await h.runRaw("set_clip_properties", args: [
            "clipIds": [videoId], "durationFrames": 30, "speed": 2.0,
        ])
        guard let videoLoc = h.editor.findClip(id: videoId),
              let audioLoc = h.editor.findClip(id: audioId) else {
            Issue.record("clips disappeared"); return
        }
        let videoClip = h.editor.timeline.tracks[videoLoc.trackIndex].clips[videoLoc.clipIndex]
        let audioClip = h.editor.timeline.tracks[audioLoc.trackIndex].clips[audioLoc.clipIndex]
        #expect(videoClip.durationFrames == 30 && audioClip.durationFrames == 30)
        #expect(videoClip.speed == 2.0 && audioClip.speed == 2.0)
    }

    @Test func setClipPropertiesOpacityDoesNotPropagateToLinkedPartner() async throws {
        let (h, videoId, audioId) = await setupLinkedPair()
        _ = await h.runRaw("set_clip_properties", args: [
            "clipIds": [videoId], "opacity": 0.5,
        ])
        guard let videoLoc = h.editor.findClip(id: videoId),
              let audioLoc = h.editor.findClip(id: audioId) else {
            Issue.record("clips disappeared"); return
        }
        let videoClip = h.editor.timeline.tracks[videoLoc.trackIndex].clips[videoLoc.clipIndex]
        let audioClip = h.editor.timeline.tracks[audioLoc.trackIndex].clips[audioLoc.clipIndex]
        #expect(videoClip.opacity == 0.5)
        #expect(audioClip.opacity == 1.0, "opacity is per-clip and must not propagate")
    }

    @Test func setClipPropertiesScalarClearsExistingKeyframeTrack() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "volume",
            "keyframes": [[0, 1.0], [30, 0.0]],
        ])
        _ = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId], "volume": 0.5,
        ])
        guard let loc = h.editor.findClip(id: clipId) else { Issue.record("clip gone"); return }
        let clip = h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        #expect(clip.volume == 0.5)
        #expect(clip.volumeTrack == nil)
    }

    // MARK: - set_keyframes

    /// Place a video clip (no linked audio) and return (harness, clipId).
    private func setupClipForKeyframes() async -> (ToolHarness, String) {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
        let asset = h.addAsset(type: .video)
        let ids = h.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60)
        return (h, ids[0])
    }

    @Test func setKeyframesSetsVolume() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "volume",
            "keyframes": [[0, 1.0], [30, 0.0, "linear"], [60, 1.0]],
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        guard let loc = h.editor.findClip(id: clipId) else { Issue.record("clip gone"); return }
        let kfs = h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].volumeTrack?.keyframes ?? []
        #expect(kfs.count == 3)
        #expect(kfs[0].frame == 0 && kfs[0].value == 1.0 && kfs[0].interpolationOut == .smooth)
        #expect(kfs[1].frame == 30 && kfs[1].value == 0.0 && kfs[1].interpolationOut == .linear)
        #expect(kfs[2].frame == 60 && kfs[2].value == 1.0)
    }

    @Test func setKeyframesClearsWhenEmpty() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "opacity",
            "keyframes": [[0, 1.0], [30, 0.0]],
        ])
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "opacity", "keyframes": [],
        ])
        guard let loc = h.editor.findClip(id: clipId) else { Issue.record("clip gone"); return }
        #expect(h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].opacityTrack == nil)
    }

    @Test func setKeyframesSortsAndDedupes() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "volume",
            "keyframes": [[60, 0.3], [0, 1.0], [30, 0.5], [30, 0.8]],
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        guard let loc = h.editor.findClip(id: clipId) else { Issue.record("clip gone"); return }
        let kfs = h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].volumeTrack?.keyframes ?? []
        #expect(kfs.map(\.frame) == [0, 30, 60])
        #expect(kfs[0].value == 1.0)
        #expect(kfs[1].value == 0.8, "duplicate frame 30 keeps the last value (last-write-wins)")
        #expect(kfs[2].value == 0.3)
    }

    @Test func setKeyframesRejectsNonFiniteValues() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "volume",
            "keyframes": [[0, Double.infinity]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("finite"))
    }

    @Test func setKeyframesAcceptsPositionAndCrop() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        let posResult = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "position",
            "keyframes": [[0, 0.5, 0.5], [30, 0.7, 0.3, "linear"]],
        ])
        #expect(posResult.isError == false, "\(ToolHarness.textOf(posResult))")
        let cropResult = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "crop",
            "keyframes": [[0, 0, 0, 0, 0], [60, 0.1, 0.1, 0.1, 0.1]],
        ])
        #expect(cropResult.isError == false, "\(ToolHarness.textOf(cropResult))")
        guard let loc = h.editor.findClip(id: clipId) else { Issue.record("clip gone"); return }
        let clip = h.editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let pos = clip.positionTrack?.keyframes ?? []
        #expect(pos.count == 2)
        #expect(pos[0].value.a == 0.5 && pos[0].value.b == 0.5)
        #expect(pos[1].value.a == 0.7 && pos[1].value.b == 0.3 && pos[1].interpolationOut == .linear)
        let crop = clip.cropTrack?.keyframes ?? []
        #expect(crop.count == 2)
        #expect(crop[1].value.top == 0.1 && crop[1].value.right == 0.1
                && crop[1].value.bottom == 0.1 && crop[1].value.left == 0.1)
    }

    @Test func setKeyframesRejectsUnknownProperty() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "loudness", "keyframes": [[0, 1.0]],
        ])
        #expect(result.isError)
    }

    @Test func setKeyframesRejectsMissingClipId() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("set_keyframes", args: [
            "clipId": "ghost", "property": "volume", "keyframes": [[0, 1.0]],
        ])
        #expect(result.isError)
    }

    @Test func getTimelineEmitsTupleKeyframes() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "volume",
            "keyframes": [[0, 1.0], [30, 0.0, "linear"]],
        ])
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "position",
            "keyframes": [[0, 0.5, 0.5], [60, 0.2, 0.8]],
        ])
        let json = try await h.runOK("get_timeline") as? [String: Any]
        let tracks = (json?["tracks"] as? [[String: Any]]) ?? []
        let clip = tracks.flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
            .first { ($0["id"] as? String) == clipId }
        let kfs = clip?["keyframes"] as? [String: Any]
        #expect(kfs != nil, "keyframes should be present on the clip in get_timeline output")
        let volRows = kfs?["volume"] as? [[Any]]
        #expect(volRows?.count == 2)
        // Default interp 'smooth' is omitted from the tuple.
        #expect(volRows?[0].count == 2)
        // Non-default interp appears as the trailing element.
        #expect(volRows?[1].count == 3)
        #expect((volRows?[1][2] as? String) == "linear")
        let posRows = kfs?["position"] as? [[Any]]
        #expect(posRows?.count == 2)
        #expect(posRows?[0].count == 3)
        // Track wrappers are removed.
        #expect(clip?["volumeTrack"] == nil)
        #expect(clip?["positionTrack"] == nil)
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
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
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
        _ = h.editor.insertTrack(at: 0, type: .audio, label: "Audio")
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
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
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
        _ = h.editor.insertTrack(at: 0, type: .video, label: "Video")
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

    @Test func createFolderAcceptsBatchEntries() async throws {
        let h = ToolHarness()
        let parentId = h.editor.createFolder(name: "Parent", in: nil)
        let json = try await h.runOK("create_folder", args: [
            "entries": [
                ["name": "A"],
                ["name": "B", "parentFolderId": parentId],
            ],
        ]) as? [String: Any]
        let folders = json?["folders"] as? [[String: Any]]
        let createdIds = Set(folders?.compactMap { $0["id"] as? String } ?? [])

        #expect(folders?.count == 2)
        #expect(h.editor.folders.contains { createdIds.contains($0.id) && $0.name == "A" && $0.parentFolderId == nil })
        #expect(h.editor.folders.contains { createdIds.contains($0.id) && $0.name == "B" && $0.parentFolderId == parentId })
    }

    @Test func createFolderBatchRejectsMissingParentBeforeMutation() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("create_folder", args: [
            "entries": [
                ["name": "Valid"],
                ["name": "Orphan", "parentFolderId": "no-such-folder"],
            ],
        ])

        #expect(result.isError)
        #expect(h.editor.folders.isEmpty)
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

    @Test func moveToFolderAcceptsBatchEntriesWithDifferentDestinations() async throws {
        let h = ToolHarness()
        let a = h.addAsset(type: .video)
        let b = h.addAsset(type: .image)
        let folderA = h.editor.createFolder(name: "A", in: nil)
        let folderB = h.editor.createFolder(name: "B", in: nil)

        let result = await h.runRaw("move_to_folder", args: [
            "entries": [
                ["assetIds": [a.id], "folderId": folderA],
                ["assetIds": [b.id], "folderId": folderB],
            ],
        ])

        #expect(result.isError == false)
        #expect(h.editor.mediaAssets.first { $0.id == a.id }?.folderId == folderA)
        #expect(h.editor.mediaAssets.first { $0.id == b.id }?.folderId == folderB)
    }

    @Test func moveToFolderBatchRejectsUnknownAssetBeforeMutation() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video)
        let folderId = h.editor.createFolder(name: "Refs", in: nil)

        let result = await h.runRaw("move_to_folder", args: [
            "entries": [
                ["assetIds": [asset.id], "folderId": folderId],
                ["assetIds": ["ghost"], "folderId": folderId],
            ],
        ])

        #expect(result.isError)
        #expect(h.editor.mediaAssets.first { $0.id == asset.id }?.folderId == nil)
    }

    @Test func renameMediaAcceptsBatchEntries() async throws {
        let h = ToolHarness()
        let a = h.addAsset(type: .video)
        let b = h.addAsset(type: .image)

        let result = await h.runRaw("rename_media", args: [
            "entries": [
                ["mediaRef": a.id, "name": "A Cut"],
                ["mediaRef": b.id, "name": "B Still"],
            ],
        ])

        #expect(result.isError == false)
        #expect(h.editor.mediaAssets.first { $0.id == a.id }?.name == "A Cut")
        #expect(h.editor.mediaAssets.first { $0.id == b.id }?.name == "B Still")
    }

    @Test func renameMediaBatchRejectsUnknownAssetBeforeMutation() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video)
        let oldName = asset.name

        let result = await h.runRaw("rename_media", args: [
            "entries": [
                ["mediaRef": asset.id, "name": "New"],
                ["mediaRef": "ghost", "name": "Ghost"],
            ],
        ])

        #expect(result.isError)
        #expect(h.editor.mediaAssets.first { $0.id == asset.id }?.name == oldName)
    }

    @Test func renameFolderAcceptsBatchEntries() async throws {
        let h = ToolHarness()
        let a = h.editor.createFolder(name: "A", in: nil)
        let b = h.editor.createFolder(name: "B", in: nil)

        let result = await h.runRaw("rename_folder", args: [
            "entries": [
                ["folderId": a, "name": "Alpha"],
                ["folderId": b, "name": "Beta"],
            ],
        ])

        #expect(result.isError == false)
        #expect(h.editor.folder(id: a)?.name == "Alpha")
        #expect(h.editor.folder(id: b)?.name == "Beta")
    }

    @Test func renameFolderBatchRejectsUnknownFolderBeforeMutation() async throws {
        let h = ToolHarness()
        let folder = h.editor.createFolder(name: "Original", in: nil)

        let result = await h.runRaw("rename_folder", args: [
            "entries": [
                ["folderId": folder, "name": "Changed"],
                ["folderId": "ghost", "name": "Ghost"],
            ],
        ])

        #expect(result.isError)
        #expect(h.editor.folder(id: folder)?.name == "Original")
    }

    @Test func deleteMediaDeletesMultipleAssets() async throws {
        let h = ToolHarness()
        let a = h.addAsset(type: .video)
        let b = h.addAsset(type: .image)

        let result = await h.runRaw("delete_media", args: ["assetIds": [a.id, b.id]])

        #expect(result.isError == false)
        #expect(h.editor.mediaAssets.contains { $0.id == a.id } == false)
        #expect(h.editor.mediaAssets.contains { $0.id == b.id } == false)
    }

    @Test func deleteFolderDeletesMultipleFolders() async throws {
        let h = ToolHarness()
        let a = h.editor.createFolder(name: "A", in: nil)
        let b = h.editor.createFolder(name: "B", in: nil)

        let result = await h.runRaw("delete_folder", args: ["folderIds": [a, b]])

        #expect(result.isError == false)
        #expect(h.editor.folder(id: a) == nil)
        #expect(h.editor.folder(id: b) == nil)
    }
}
