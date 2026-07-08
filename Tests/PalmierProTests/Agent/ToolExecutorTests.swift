import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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

    /// Like addAsset, but also registers a manifest entry so library reads (get_media) see it.
    @discardableResult
    func makeAsset(name: String, type: ClipType = .video, duration: Double = 5) -> MediaAsset {
        let asset = addAsset(type: type, duration: duration)
        asset.name = name
        editor.mediaManifest.entries.append(MediaManifestEntry(
            id: asset.id, name: name, type: type,
            source: .external(absolutePath: asset.url.path), duration: duration
        ))
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

@Suite("ToolExecutor — import_media")
@MainActor
struct ToolExecutorImportMediaTests {
    @Test func importBytesWritesFileAndRegistersAsset() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-import-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let h = ToolHarness()
        h.editor.projectURL = root.appendingPathComponent("Import.palmier", isDirectory: true)
        let bytes = Data("fake-png".utf8).base64EncodedString()

        let result = await h.runRaw("import_media", args: [
            "source": ["bytes": bytes, "mimeType": "image/png"],
            "name": "Imported Still",
        ])

        #expect(result.isError == false)
        let asset = try #require(h.editor.mediaAssets.first)
        #expect(asset.name == "Imported Still")
        #expect(asset.type == .image)
        #expect(FileManager.default.fileExists(atPath: asset.url.path))
        #expect(h.editor.mediaManifest.entries.first?.name == "Imported Still")
    }

    @Test func importPathCreatesPlaceholderAndCopiesIntoProject() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-import-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.png")
        try writeTestPNG(to: source)

        let h = ToolHarness()
        h.editor.projectURL = root.appendingPathComponent("Import.palmier", isDirectory: true)

        let result = await h.runRaw("import_media", args: [
            "source": ["path": source.path],
            "name": "Copied Still",
        ])

        #expect(result.isError == false)
        let body = try JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any]
        #expect(body?["status"] as? String == "downloading")
        #expect(body?["mediaRef"] is String)
        let asset = try #require(h.editor.mediaAssets.first)
        #expect(asset.name == "Copied Still")
        #expect(asset.type == .image)
        #expect(asset.url.path.contains("/Import.palmier/media/imported-"))
        #expect(h.editor.mediaManifest.entries.first?.importInput?.sourcePath == source.path)

        try await waitForImportCompletion(in: h.editor, assetId: asset.id)

        #expect(asset.generationStatus == .none)
        #expect(asset.importInput == nil)
        #expect(FileManager.default.fileExists(atPath: asset.url.path))
        #expect(h.editor.mediaManifest.entries.first?.importInput == nil)
    }

    @Test func importPathLeavesUnreadableMediaFailed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-import-invalid-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.png")
        try Data("fake-png".utf8).write(to: source)

        let h = ToolHarness()
        h.editor.projectURL = root.appendingPathComponent("Import.palmier", isDirectory: true)

        let result = await h.runRaw("import_media", args: [
            "source": ["path": source.path],
            "name": "Unreadable Still",
        ])

        #expect(result.isError == false)
        let asset = try #require(h.editor.mediaAssets.first)
        try await waitForImportFailure(in: h.editor, assetId: asset.id)

        #expect(asset.generationStatus == .failed("Could not read media file."))
        #expect(asset.importInput?.sourcePath == source.path)
        #expect(h.editor.mediaManifest.entries.first?.importInput?.sourcePath == source.path)
    }

    @Test func unreadableFinalizeRefreshesTimelinePreview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-finalize-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("bad.png")
        try Data("fake-png".utf8).write(to: source)

        let editor = EditorViewModel()
        let asset = MediaAsset(id: "bad-image", url: source, type: .image, name: "Bad Still")
        asset.importInput = MediaImportInput(sourcePath: source.path, createdAt: Date())
        asset.generationStatus = .downloading
        editor.importMediaAsset(asset)
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(mediaRef: asset.id, mediaType: .image, start: 0, duration: 30),
            ]),
        ])
        let before = editor.timelineRenderRevision

        let finalized = await editor.finalizeImportedAsset(asset)

        #expect(finalized == false)
        #expect(editor.timelineRenderRevision == before + 1)
    }

    private func waitForImportCompletion(in editor: EditorViewModel, assetId: String) async throws {
        for _ in 0..<100 {
            if let status = editor.mediaAssets.first(where: { $0.id == assetId })?.generationStatus,
               status == .none {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("import did not complete")
    }

    private func waitForImportFailure(in editor: EditorViewModel, assetId: String) async throws {
        for _ in 0..<100 {
            if let status = editor.mediaAssets.first(where: { $0.id == assetId })?.generationStatus,
               case .failed = status {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("import did not fail")
    }

    private func writeTestPNG(to url: URL) throws {
        let width = 2
        let height = 2
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ToolExecutorImportMediaTests", code: 1)
        }
    }
}

@Suite("ToolExecutor — read-only handlers")
@MainActor
struct ToolExecutorReadOnlyTests {

    // MARK: - get_timeline

    @Test func getTimelineReflectsCurrentTracksAndFrame() async throws {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 50)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(start: 0, duration: 100)]),
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
            Fixtures.videoTrack(clips: [clip]),
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
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 50)]),
        ])
        let h = ToolHarness(timeline: timeline)

        let json = try await h.runOK("get_timeline") as? [String: Any]
        let track = Self.firstTrack(json)
        #expect(track?["muted"] == nil)
        #expect(track?["hidden"] == nil)
        #expect(track?["syncLocked"] == nil)
        #expect(track?["label"] as? String == "V1")
        // No tool consumes track ids or UI fields; the index is what tools take.
        #expect(track?["id"] == nil)
        #expect(track?["displayHeight"] == nil)
        #expect(track?["index"] as? Int == 0)
        #expect(track?["gaps"] == nil)
        #expect(json?["settingsConfigured"] == nil)
        #expect(json?["durationSeconds"] as? Double == 1.667)

        let clip = (track?["clips"] as? [[String: Any]])?.first
        #expect(clip?["id"] as? String == "c1")
        #expect(clip?["mediaRef"] as? String == "media-1")
        #expect(clip?["frames"] as? [Int] == [0, 50])
        #expect(clip?["startFrame"] == nil)
        #expect(clip?["durationFrames"] == nil)
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
            Fixtures.videoTrack(clips: [video] + clips),
        ])
        let h = ToolHarness(timeline: timeline)

        let json = try await h.runOK("get_timeline") as? [String: Any]
        let loose = Self.firstTrack(json)?["clips"] as? [[String: Any]]
        #expect(loose?.count == 1)
        #expect(loose?.first?["id"] as? String == "v1")

        // Default is a summary: no per-clip rows, no caption clip ids.
        let group = Self.firstCaptionGroup(json)
        #expect(group?["captionGroupId"] as? String == "g1")
        #expect(group?["clipCount"] as? Int == 3)
        #expect(group?["frameRange"] as? [Int] == [0, 90])
        #expect(group?["clips"] == nil)
        #expect(group?["textPreview"] as? String == "one … three")
        #expect((group?["clipsNote"] as? String)?.contains("captionDetail") == true)

        let shared = group?["shared"] as? [String: Any]
        #expect(shared?["mediaType"] as? String == "text")
        #expect((shared?["textStyle"] as? [String: Any])?["fontName"] as? String == "Avenir")
        let sharedTransform = shared?["transform"] as? [String: Any]
        #expect(sharedTransform?["centerY"] as? Double == 0.85)
        #expect(sharedTransform?["width"] == nil)
        #expect(sharedTransform?["height"] == nil)

        // captionDetail expands to [clipId, startFrame, durationFrames, text] rows.
        let detail = try await h.runOK("get_timeline", args: ["captionDetail": true]) as? [String: Any]
        let rows = Self.firstCaptionGroup(detail)?["clips"] as? [[Any]]
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
            Fixtures.videoTrack(clips: clips),
        ])
        let h = ToolHarness(timeline: timeline)

        let json = try await h.runOK("get_timeline", args: ["captionDetail": true]) as? [String: Any]
        let group = Self.firstCaptionGroup(json)
        #expect(group?["clipCount"] as? Int == 2)
        #expect((group?["clips"] as? [[Any]])?.count == 2)

        let loose = Self.firstTrack(json)?["clips"] as? [[String: Any]]
        #expect(loose?.count == 1)
        #expect(loose?.first?["id"] as? String == "cap-1")
        #expect(loose?.first?["captionGroupId"] as? String == "g1")
    }

    @Test func getTimelineReportsTrackGaps() async throws {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 30, duration: 30),
                Fixtures.clip(id: "b", start: 90, duration: 30),
                Fixtures.clip(id: "c", start: 120, duration: 30),
            ]),
        ])
        let h = ToolHarness(timeline: timeline)
        let json = try await h.runOK("get_timeline") as? [String: Any]
        // Internal gap [60, 90) only; leading space shows as clip a's startFrame.
        #expect(Self.firstTrack(json)?["gaps"] as? [[Int]] == [[60, 90]])
    }

    @Test func getTimelineWindowsClipsToRequestedRange() async throws {
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
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
            Fixtures.videoTrack(clips: clips),
        ]))

        let json = try await h.runOK("get_timeline", args: ["captionDetail": true]) as? [String: Any]
        let group = Self.firstCaptionGroup(json)
        #expect(group?["clipCount"] as? Int == 250)
        #expect((group?["clips"] as? [[Any]])?.count == 200)
        #expect((group?["clipsNote"] as? String)?.contains("250") == true)

        // Windowing pages past the cap.
        let paged = try await h.runOK("get_timeline", args: [
            "startFrame": 6000, "endFrame": 7500, "captionDetail": true,
        ]) as? [String: Any]
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
            Fixtures.videoTrack(clips: clips),
        ]))

        let json = try await h.runOK("get_timeline") as? [String: Any]
        #expect(Self.firstCaptionGroup(json)?["clipCount"] as? Int == 3)
        #expect(Self.firstTrack(json)?["clips"] == nil)
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

    @Test func getMediaOnEmptyManifestReturnsEmptyAssets() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("get_media") as? [String: Any]
        let assets = json?["assets"] as? [Any]
        #expect(assets?.isEmpty == true)
        // Unfiltered reads include the timelines inventory.
        let timelines = json?["timelines"] as? [[String: Any]]
        #expect(timelines?.count == 1)
        #expect(timelines?.first?["active"] as? Bool == true)
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
        let assets = json?["assets"] as? [[String: Any]]
        let entry = assets?.first
        #expect(entry?["durationSeconds"] as? Double == 12.346)
        #expect(entry?["fps"] as? Double == 29.97)
        // Generated assets keep their prompt as a content hint; internals stay hidden.
        #expect(entry?["prompt"] as? String == "Generate")
        #expect(entry?["generationInput"] == nil)
        #expect(entry?["source"] == nil)
    }

    @Test func getMediaReportsFolderPathsAndScopesByFolder() async throws {
        let h = ToolHarness()
        let refs = h.editor.createFolder(name: "Refs", in: nil)
        let sub = h.editor.createFolder(name: "Sub", in: refs)
        let inSub = h.makeAsset(name: "a")
        let atRoot = h.makeAsset(name: "b")
        h.editor.moveAssetsToFolder(assetIds: [inSub.id], folderId: sub)

        let json = try await h.runOK("get_media") as? [String: Any]
        #expect(json?["folders"] as? [String] == ["Refs", "Refs/Sub"])
        let assets = json?["assets"] as? [[String: Any]]
        let filed = assets?.first { $0["name"] as? String == "a" }
        #expect(filed?["folder"] as? String == "Refs/Sub")

        // Folder filter includes subfolders and omits the inventory sections.
        let scoped = try await h.runOK("get_media", args: ["folder": "Refs"]) as? [String: Any]
        let scopedAssets = scoped?["assets"] as? [[String: Any]]
        #expect(scopedAssets?.count == 1)
        #expect(scopedAssets?.first?["name"] as? String == "a")
        #expect(scoped?["timelines"] == nil)
        _ = atRoot
    }

    @Test func getMediaIdsFilterReturnsOnlyThoseAssets() async throws {
        let h = ToolHarness()
        let a = h.makeAsset(name: "a")
        _ = h.makeAsset(name: "b")
        let json = try await h.runOK("get_media", args: ["ids": [a.id]]) as? [String: Any]
        let assets = json?["assets"] as? [[String: Any]]
        #expect(assets?.count == 1)
        #expect((assets?.first?["id"] as? String).map { a.id.hasPrefix($0) } == true)
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
        _ = h.editor.insertTrack(at: 0, type: .video)
        let asset = h.addAsset(type: .video)
        return (h, asset)
    }

    // MARK: - set_clip_properties speed

    @Test func setSpeedRescalesDurationToPreserveSource() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)]),
        ]))
        let result = await h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "speed": 2.0])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let clip = h.editor.timeline.tracks[0].clips[0]
        #expect(clip.speed == 2.0)
        #expect(clip.durationFrames == 50)  // 100 source frames now play in half the time
    }

    @Test func setSpeedWithExplicitDurationKeepsThatDuration() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)]),
        ]))
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": ["c1"], "speed": 2.0, "durationFrames": 80,
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let clip = h.editor.timeline.tracks[0].clips[0]
        #expect(clip.speed == 2.0)
        #expect(clip.durationFrames == 80)  // explicit duration wins over the speed rescale
    }

    @Test func setHalfSpeedDoublesDuration() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)]),
        ]))
        _ = await h.runRaw("set_clip_properties", args: ["clipIds": ["c1"], "speed": 0.5])
        let clip = h.editor.timeline.tracks[0].clips[0]
        #expect(clip.speed == 0.5)
        #expect(clip.durationFrames == 200)
    }

    @Test func setSpeedRescalesTextWordTimings() async throws {
        var clip = Fixtures.clip(id: "caption", mediaRef: "text", mediaType: .text, start: 0, duration: 120)
        clip.textContent = "one two"
        clip.wordTimings = [
            WordTiming(text: "one", startFrame: 0, endFrame: 60),
            WordTiming(text: "two", startFrame: 60, endFrame: 120),
        ]
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))

        let result = await h.runRaw("set_clip_properties", args: ["clipIds": ["caption"], "speed": 2.0])

        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let updated = h.editor.timeline.tracks[0].clips[0]
        #expect(updated.durationFrames == 60)
        #expect(updated.wordTimings == [
            WordTiming(text: "one", startFrame: 0, endFrame: 30),
            WordTiming(text: "two", startFrame: 30, endFrame: 60),
        ])
    }

    // MARK: - add_clips

    @Test func addClipsPlacesClipOnTrack() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let result = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "endFrame": 60,
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
                "endFrame": 30,
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
                "endFrame": 30,
            ]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("not found"))
    }

    @Test func addClipsRejectsIncompatibleAssetForTrack() async throws {
        // Audio asset onto a video track.
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video)
        let audio = h.addAsset(type: .audio)
        let result = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": audio.id,
                "trackIndex": 0,
                "startFrame": 0,
                "endFrame": 30,
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
                "endFrame": 0,
            ]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("endFrame"))
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
                "endFrame": 30,
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
                ["mediaRef": a.id, "startFrame": 0, "endFrame": 30],
                ["mediaRef": b.id, "startFrame": 60, "endFrame": 90],
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
                ["mediaRef": video.id, "startFrame": 0, "endFrame": 30],
                ["mediaRef": audio.id, "startFrame": 0, "endFrame": 30],
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
                ["mediaRef": audio1.id, "startFrame": 0, "endFrame": 30],
                ["mediaRef": video.id, "startFrame": 0, "endFrame": 30],
                ["mediaRef": audio2.id, "startFrame": 60, "endFrame": 90],
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
        _ = h.editor.insertTrack(at: 0, type: .video)
        let a = h.addAsset(type: .video)
        let b = h.addAsset(type: .video)
        let result = await h.runRaw("add_clips", args: [
            "entries": [
                ["mediaRef": a.id, "trackIndex": 0, "startFrame": 0, "endFrame": 30],
                ["mediaRef": b.id, "startFrame": 60, "endFrame": 90], // omitted trackIndex
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
                ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "endFrame": 30],
                ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 60, "endFrame": 90],
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
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "endFrame": 30]]
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
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "endFrame": 30]]
        ])
        let clipId = h.editor.timeline.tracks[0].clips[0].id

        let json = try await h.runOK("remove_clips", args: ["clipIds": [clipId]]) as? [String: Any]
        #expect((json?["removedClipIds"] as? [String])?.count == 1)
        // The removed id must come back as a short prefix, not a full UUID.
        #expect(((json?["removedClipIds"] as? [String])?.first?.count ?? 99) < 36)
        let notes = (json?["notes"] as? [String])?.joined(separator: " ") ?? ""
        #expect(notes.contains("Track indices shifted"), "expected track-shift note, got: \(notes)")
    }

    @Test func removeClipsOmitsTrackShiftNoteWhenNoTrackPruned() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [
                ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "endFrame": 30],
                ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 60, "endFrame": 90],
            ]
        ])
        let clipId = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }[0].id

        let json = try await h.runOK("remove_clips", args: ["clipIds": [clipId]]) as? [String: Any]
        let notes = (json?["notes"] as? [String])?.joined(separator: " ") ?? ""
        #expect(!notes.contains("Track indices shifted"), "no track was pruned but the shift note appeared: \(notes)")
    }

    @Test func removeClipsRejectsMissingIds() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("remove_clips", args: ["clipIds": ["does-not-exist"]])
        #expect(result.isError)
    }

    // MARK: - split_clips

    @Test func splitClipRejectsFrameOutsideClipRange() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "endFrame": 60,
            ]]
        ])
        let clipId = h.editor.timeline.tracks[0].clips[0].id

        // Split at endFrame should fail (must be strictly inside).
        let result = await h.runRaw("split_clips", args: ["splits": [["clipId": clipId, "atFrame": 60]]])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("outside"))
    }

    @Test func splitClipsMultipleFramesOnSameClip() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "endFrame": 90,
            ]]
        ])

        // Two cuts on one clip via the trackIndex+frames mode → three segments.
        let result = await h.runRaw("split_clips", args: ["trackIndex": 0, "frames": [30, 60]])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let clips = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.count == 3)
        #expect(clips[0].startFrame == 0 && clips[0].durationFrames == 30)
        #expect(clips[1].startFrame == 30 && clips[1].durationFrames == 30)
        #expect(clips[2].startFrame == 60 && clips[2].durationFrames == 30)
    }

    @Test func splitClipsDedupsDuplicateFrames() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "endFrame": 90]]
        ])
        let json = try await h.runOK("split_clips", args: ["trackIndex": 0, "frames": [30, 30]]) as? [String: Any]
        #expect(h.editor.timeline.tracks[0].clips.count == 2)
        // Both halves come back with their resulting frames.
        let frames = (json?["clips"] as? [[String: Any]])?.compactMap { $0["frames"] as? [Int] }
        #expect(frames == [[0, 30], [30, 90]])
    }

    @Test func splitClipsRejectsSeamFrame() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "endFrame": 90]]
        ])
        _ = await h.runRaw("split_clips", args: ["trackIndex": 0, "frames": [30]])
        // Frame 30 is now a seam between two clips — strictly inside neither.
        let result = await h.runRaw("split_clips", args: ["trackIndex": 0, "frames": [30]])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not strictly inside"))
    }

    @Test func splitClipsRejectsBothAndNeitherMode() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "endFrame": 90]]
        ])
        let clipId = h.editor.timeline.tracks[0].clips[0].id

        let both = await h.runRaw("split_clips", args: [
            "splits": [["clipId": clipId, "atFrame": 30]], "trackIndex": 0, "frames": [60],
        ])
        #expect(both.isError)

        let neither = await h.runRaw("split_clips", args: [:])
        #expect(neither.isError)
    }

    @Test func splitClipsEmptySplitsFallsThroughToTrackMode() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 0, "endFrame": 90]]
        ])
        // Empty splits + valid trackIndex/frames must apply the track cuts, not error out.
        let result = await h.runRaw("split_clips", args: ["splits": [], "trackIndex": 0, "frames": [30]])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        #expect(h.editor.timeline.tracks[0].clips.count == 2)
    }

    // MARK: - move_clips

    /// Add a video clip and return its id, for tests that need an existing clip.
    private func addedClip(in h: ToolHarness, asset: MediaAsset, duration: Int = 60) async -> String {
        _ = await h.runRaw("add_clips", args: [
            "entries": [[
                "mediaRef": asset.id,
                "trackIndex": 0,
                "startFrame": 0,
                "endFrame": duration,
            ]]
        ])
        return h.editor.timeline.tracks[0].clips[0].id
    }

    @Test func moveClipsChangesTrackAndFrame() async throws {
        let (h, asset) = await setupWithVideoTrack()
        _ = h.editor.insertTrack(at: 0, type: .video)
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
        _ = h.editor.insertTrack(at: 0, type: .audio)
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
        _ = h.editor.insertTrack(at: 0, type: .video)
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
        // The moved clip comes back with resulting frames and its folded audio partner.
        let json = try JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any]
        let clip = (json?["clips"] as? [[String: Any]])?.first
        #expect(clip?["frames"] as? [Int] == [60, 120])
        #expect((clip?["audio"] as? [String: Any])?["id"] != nil)
    }

    @Test func moveClipsTrackChangeDoesNotMoveLinkedPartner() async throws {
        let (h, videoId, audioId) = await setupLinkedPair()
        // Add a second video track so the video has somewhere to move to.
        _ = h.editor.insertTrack(at: 0, type: .video)
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

    @Test func setClipPropertiesAppliesUniformlyToMultipleClips() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let id1 = await addedClip(in: h, asset: asset, duration: 30)
        // Place a second clip at a non-overlapping range on the same track.
        _ = await h.runRaw("add_clips", args: [
            "entries": [["mediaRef": asset.id, "trackIndex": 0, "startFrame": 60, "endFrame": 90]]
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

    @Test func setClipPropertiesRejectsTextFieldsAsUnknown() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId], "fontSize": 48,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("unknown field"))
    }

    @Test func updateTextRejectsNonTextClip() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let result = await h.runRaw("update_text", args: [
            "clipIds": [clipId], "fontSize": 48,
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("only applies to text"))
    }

    @Test func updateTextRejectsRemovedTextStyleFields() async {
        var clip = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 30)
        clip.textStyle = TextStyle()
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))

        let result = await h.runRaw("update_text", args: [
            "clipIds": ["title"],
            "borderEnabled": false,
            "shadowColor": "#000000",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("unknown field"))
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

    @Test func setClipPropertiesRejectsOutOfRangeValues() async throws {
        let (h, asset) = await setupWithVideoTrack()
        let clipId = await addedClip(in: h, asset: asset)
        let cases: [(String, Any)] = [
            ("speed", 0.0), ("speed", -2.0),
            ("volume", 5.0), ("opacity", -1.0), ("trimStartFrame", -100),
        ]
        for (field, value) in cases {
            var args: [String: Any] = ["clipIds": [clipId]]
            args[field] = value
            let result = await h.runRaw("set_clip_properties", args: args)
            #expect(result.isError, "\(field)=\(value) should be rejected")
            #expect(ToolHarness.textOf(result).contains(field), "error should name \(field)")
        }
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
        _ = h.editor.insertTrack(at: 0, type: .video)
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
            .first { ($0["id"] as? String).map { clipId.hasPrefix($0) } == true }
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

    @Test func getTimelineCollapsesConstantAndIdentityKeyframes() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "crop",
            "keyframes": [[0, 0, 0, 0, 0.313], [36, 0, 0, 0, 0.313]],
        ])
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "position",
            "keyframes": [[0, 0, 0]],
        ])
        let json = try await h.runOK("get_timeline") as? [String: Any]
        let clip = ((json?["tracks"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
            .first { ($0["id"] as? String).map { clipId.hasPrefix($0) } == true }
        // Constant crop reads as the static field; identity position vanishes.
        #expect(clip?["keyframes"] == nil)
        #expect((clip?["crop"] as? [String: Any])?["left"] as? Double == 0.313)
    }

    @Test func addClipsReportsOverwrittenAndTrimmedNeighbors() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video, duration: 10)
        _ = await h.runRaw("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "endFrame": 60],
            ["mediaRef": asset.id, "startFrame": 90, "endFrame": 120],
        ]])
        let victim = h.editor.timeline.tracks[0].clips[1].id

        // Lands on [40, 120): trims the first clip's tail, removes the second entirely.
        let json = try await h.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "trackIndex": 0, "startFrame": 40, "endFrame": 120],
        ]]) as? [String: Any]
        let frames = (json?["clips"] as? [[String: Any]])?.compactMap { $0["frames"] as? [Int] }
        #expect(frames == [[0, 40], [40, 120]])
        #expect((json?["removedClipIds"] as? [String])?.count == 1)
        #expect(((json?["removedClipIds"] as? [String])?.first).map { victim.hasPrefix($0) } == true)
    }

    @Test func insertClipsCompressesDownstreamShiftIntoRule() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video, duration: 10)
        var entries: [[String: Any]] = []
        for i in 0..<4 {
            entries.append(["mediaRef": asset.id, "startFrame": i * 30, "endFrame": i * 30 + 30])
        }
        _ = await h.runRaw("add_clips", args: ["entries": entries])

        let json = try await h.runOK("insert_clips", args: [
            "trackIndex": 0, "atFrame": 30,
            "entries": [["mediaRef": asset.id, "durationFrames": 60]],
        ]) as? [String: Any]
        // The inserted clip is enumerated; the three downstream clips compress to one rule.
        let inserted = (json?["clips"] as? [[String: Any]])?.first
        #expect(inserted?["frames"] as? [Int] == [30, 90])
        let shift = (json?["shifted"] as? [[String: Any]])?.first
        #expect(shift?["by"] as? Int == 60)
        #expect(shift?["count"] as? Int == 3)
        #expect(shift?["fromFrame"] as? Int == 30)
    }

    @Test func addClipsAcceptsSourceSecondsSpan() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video, duration: 10)
        let json = try await h.runOK("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [2.0, 5.0]],
        ]]) as? [String: Any]
        let clip = (json?["clips"] as? [[String: Any]])?.first
        // 30fps: seconds [2, 5] → trimStart 60, duration 90.
        #expect(clip?["frames"] as? [Int] == [0, 90])
        #expect(clip?["trimStartFrame"] as? Int == 60)

        let mixed = await h.runRaw("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "source": [2.0, 5.0], "endFrame": 30],
        ]])
        #expect(mixed.isError)
    }

    @Test func setClipPropertiesEchoesResultingValuesAndKeyframeClear() async throws {
        let (h, clipId) = await setupClipForKeyframes()
        _ = await h.runRaw("set_keyframes", args: [
            "clipId": clipId, "property": "volume",
            "keyframes": [[0, 1.0], [30, 0.0]],
        ])
        let json = try await h.runOK("set_clip_properties", args: [
            "clipIds": [clipId], "volume": 0.5, "speed": 2.0,
        ]) as? [String: Any]
        let clip = (json?["clips"] as? [[String: Any]])?.first
        // Resulting values visible: halved duration from speed, scalar volume, keyframes gone.
        #expect(clip?["volume"] as? Double == 0.5)
        #expect(clip?["speed"] as? Double == 2.0)
        #expect(clip?["keyframes"] == nil)
        #expect(((json?["notes"] as? [String])?.first ?? "").contains("cleared existing keyframes"))
    }

    @Test func applyColorEchoesGradeAndRoundTrips() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video, duration: 10)
        _ = await h.runRaw("add_clips", args: ["entries": [
            ["mediaRef": asset.id, "startFrame": 0, "endFrame": 60],
            ["mediaRef": asset.id, "startFrame": 60, "endFrame": 120],
        ]])
        let a = h.editor.timeline.tracks[0].clips[0].id
        let b = h.editor.timeline.tracks[0].clips[1].id

        let graded = try await h.runOK("apply_color", args: [
            "clipIds": [a], "exposure": 0.4, "temperature": 7200.0,
            "masterCurve": [[0, 0.05], [1, 0.95]],
        ]) as? [String: Any]
        let color = ((graded?["clips"] as? [[String: Any]])?.first?["color"]) as? [String: Any]
        #expect(color?["exposure"] as? Double == 0.4)
        #expect(color?["temperature"] as? Double == 7200)
        #expect((color?["masterCurve"] as? [[Double]])?.count == 2)
        // color.* effects live in `color`, not `effects`.
        #expect((graded?["clips"] as? [[String: Any]])?.first?["effects"] == nil)

        // Paste the grade onto clip B; both now read identically.
        let pasted = try await h.runOK("apply_color", args: [
            "clipIds": [b], "color": color!,
        ]) as? [String: Any]
        let bColor = ((pasted?["clips"] as? [[String: Any]])?.first?["color"]) as? [String: Any]
        #expect(bColor?["exposure"] as? Double == 0.4)
        #expect(bColor?["temperature"] as? Double == 7200)

        // Paste + knobs together is rejected.
        let mixed = await h.runRaw("apply_color", args: ["clipIds": [b], "color": color!, "exposure": 1.0])
        #expect(mixed.isError)

        // Touching one wheel doesn't leak the other zones' neutral values into the echo.
        let wheels = try await h.runOK("apply_color", args: [
            "clipIds": [a], "shadowsHue": 180.0, "shadowsAmount": 0.12,
        ]) as? [String: Any]
        let wColor = ((wheels?["clips"] as? [[String: Any]])?.first?["color"]) as? [String: Any]
        #expect(wColor?["shadowsHue"] as? Double == 180)
        #expect(wColor?["shadowsAmount"] as? Double == 0.12)
        #expect(wColor?["midsGamma"] == nil)
        #expect(wColor?["highsGain"] == nil)
        #expect(wColor?["midsHue"] == nil)
    }

    @Test func applyEffectEchoesCleanEffectShape() async throws {
        let h = ToolHarness()
        let asset = h.addAsset(type: .video, duration: 10)
        _ = await h.runRaw("add_clips", args: ["entries": [["mediaRef": asset.id, "startFrame": 0, "endFrame": 60]]])
        let id = h.editor.timeline.tracks[0].clips[0].id

        let json = try await h.runOK("apply_effect", args: [
            "clipIds": [id], "effects": [["type": "blur.gaussian", "params": ["radius": 12.0]]],
        ]) as? [String: Any]
        let fx = ((json?["clips"] as? [[String: Any]])?.first?["effects"] as? [[String: Any]])?.first
        #expect(fx?["type"] as? String == "blur.gaussian")
        #expect((fx?["params"] as? [String: Any])?["radius"] as? Double == 12)
        // No UUID, no enabled:true noise.
        #expect(fx?["id"] == nil)
        #expect(fx?["enabled"] == nil)
    }

    @Test func setProjectSettingsReturnsChangedFieldsAsJSON() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("set_project_settings", args: ["fps": 60]) as? [String: Any]
        #expect(json?["fps"] as? Int == 60)
        #expect(json?["changed"] as? [String] == ["fps"])
        #expect((json?["note"] as? String)?.contains("re-read") == true)

        let noop = try await h.runOK("set_project_settings", args: ["fps": 60]) as? [String: Any]
        #expect(noop?["changed"] as? [String] == [])
        #expect(noop?["note"] as? String == "Settings already matched.")
    }

    @Test func visibleClipsListsTopDownAndCollapsesCaptionGroups() async throws {
        var caption = Fixtures.clip(id: "cap-0", mediaType: .text, start: 0, duration: 90)
        caption.captionGroupId = "g1"
        var hiddenTrack = Fixtures.videoTrack(clips: [Fixtures.clip(id: "hidden", start: 0, duration: 90)])
        hiddenTrack.hidden = true
        let timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [caption]),
            hiddenTrack,
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "main", start: 0, duration: 60),
                Fixtures.clip(id: "later", start: 60, duration: 30),
            ]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "aud", mediaType: .audio, start: 0, duration: 90)]),
        ])
        #expect(ToolExecutor.visibleClips(at: 30, in: timeline) == ["g1", "main"])
        #expect(ToolExecutor.visibleClips(at: 70, in: timeline) == ["g1", "later"])
    }

    @Test func getTimelineFoldsLinkedAudioIntoVideoClip() async throws {
        let h = ToolHarness()
        h.addAsset(id: "av-src", duration: 10, hasAudio: true)
        _ = await h.runRaw("add_clips", args: ["entries": [
            ["mediaRef": "av-src", "startFrame": 0, "endFrame": 60],
        ]])
        let audioClip = h.editor.timeline.tracks.first { $0.type == .audio }?.clips.first
        let audioId = try #require(audioClip?.id)
        _ = await h.runRaw("set_clip_properties", args: ["clipIds": [audioId], "volume": 0.0])

        let json = try await h.runOK("get_timeline") as? [String: Any]
        let tracks = (json?["tracks"] as? [[String: Any]]) ?? []
        let videoTrack = tracks.first { $0["type"] as? String == "video" }
        let audioTrack = tracks.first { $0["type"] as? String == "audio" }

        let video = (videoTrack?["clips"] as? [[String: Any]])?.first
        let audio = video?["audio"] as? [String: Any]
        #expect((audio?["id"] as? String).map { audioId.hasPrefix($0) } == true)
        #expect(audio?["track"] as? Int == audioTrack?["index"] as? Int)
        #expect(audio?["volume"] as? Double == 0)
        #expect(video?["linkGroupId"] == nil)

        // The partner is not repeated on its own track; a count stands in.
        #expect(audioTrack?["clips"] == nil)
        #expect(audioTrack?["linkedClips"] as? Int == 1)
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
                "endFrame": 90,
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
        _ = h.editor.insertTrack(at: 0, type: .video)
        let result = await h.runRaw("add_texts", args: [
            "entries": [[
                "trackIndex": 0,
                "startFrame": 30,
                "endFrame": 90,
                "content": "Caption",
                "fontSize": 48,
            ]]
        ])
        #expect(result.isError == false)
        let clip = h.editor.timeline.tracks[0].clips[0]
        #expect(clip.textContent == "Caption")
        #expect(clip.textStyle?.fontSize == 48)
    }

    @Test func addTextsAppliesRichTextStyleFields() async throws {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video)
        let result = await h.runRaw("add_texts", args: [
            "entries": [[
                "trackIndex": 0,
                "startFrame": 0,
                "endFrame": 60,
                "content": "Styled",
                "fontName": "Georgia",
                "fontSize": 54,
                "isBold": false,
                "isItalic": true,
                "color": "#F0E0D0",
                "alignment": "right",
                "borderColor": "#102030",
                "backgroundColor": "#01020380",
            ]]
        ])

        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let style = h.editor.timeline.tracks[0].clips[0].textStyle
        #expect(style?.fontName == "Georgia")
        #expect(style?.fontSize == 54)
        #expect(style?.isBold == false)
        #expect(style?.isItalic == true)
        #expect(style?.color == TextStyle.RGBA(hex: "#F0E0D0"))
        #expect(style?.alignment == .right)
        #expect(style?.border.enabled == true)
        #expect(style?.border.color == TextStyle.RGBA(hex: "#102030"))
        #expect(style?.background.enabled == true)
        #expect(style?.background.color == TextStyle.RGBA(hex: "#01020380"))
    }

    @Test func addTextsRejectsAudioTargetTrack() async throws {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .audio)
        let result = await h.runRaw("add_texts", args: [
            "entries": [[
                "trackIndex": 0,
                "startFrame": 0,
                "endFrame": 30,
                "content": "Subtitle",
            ]]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).lowercased().contains("audio"))
    }

    @Test func addTextsRejectsMixedTrackIndexUsage() async throws {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video)
        let result = await h.runRaw("add_texts", args: [
            "entries": [
                ["trackIndex": 0, "startFrame": 0, "endFrame": 30, "content": "A"],
                ["startFrame": 60, "endFrame": 90, "content": "B"], // missing trackIndex
            ]
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Mixed trackIndex"))
    }

    @Test func addTextsRejectsZeroDuration() async throws {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video)
        let result = await h.runRaw("add_texts", args: [
            "entries": [[
                "trackIndex": 0,
                "startFrame": 0,
                "endFrame": 0,
                "content": "x",
            ]]
        ])
        #expect(result.isError)
    }

    // MARK: - organize_media

    @Test func organizeCreatesNestedFolderPathsAndIsIdempotent() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("organize_media", args: [
            "createFolders": ["Refs/Stills"],
        ]) as? [String: Any]
        #expect(json?["createdFolders"] as? [String] == ["Refs", "Refs/Stills"])
        #expect(h.editor.folders.count == 2)

        // Get-or-create: re-running reports an empty result and creates nothing.
        let again = try await h.runOK("organize_media", args: [
            "createFolders": ["Refs/Stills"],
        ]) as? [String: Any]
        #expect(again?["createdFolders"] == nil)
        #expect(h.editor.folders.count == 2)
    }

    @Test func organizeMovesAssetsIntoPathCreatedOnDemand() async throws {
        let h = ToolHarness()
        let asset = h.makeAsset(name: "clip")
        let json = try await h.runOK("organize_media", args: [
            "moves": [["items": [asset.id], "into": "Refs"]],
        ]) as? [String: Any]
        #expect(json?["moved"] as? Int == 1)
        #expect(json?["createdFolders"] as? [String] == ["Refs"])
        let folderId = h.editor.folders.first { $0.name == "Refs" }?.id
        #expect(h.editor.mediaAssets.first { $0.id == asset.id }?.folderId == folderId)

        // Omitting 'into' moves back to the root.
        _ = try await h.runOK("organize_media", args: ["moves": [["items": [asset.id]]]])
        #expect(h.editor.mediaAssets.first { $0.id == asset.id }?.folderId == nil)
    }

    @Test func organizeReparentsFoldersAndRejectsCycles() async throws {
        let h = ToolHarness()
        let a = h.editor.createFolder(name: "A", in: nil)
        let b = h.editor.createFolder(name: "B", in: a)
        _ = b

        let result = await h.runRaw("organize_media", args: [
            "moves": [["items": ["A"], "into": "A/B"]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("into itself"))

        // A rejected cycle must not leave partially-created destination folders behind.
        let deepCycle = await h.runRaw("organize_media", args: [
            "moves": [["items": ["A"], "into": "A/B/Deep"]],
        ])
        #expect(deepCycle.isError)
        #expect(h.editor.folders.count == 2)

        _ = try await h.runOK("organize_media", args: [
            "moves": [["items": ["A/B"], "into": "Elsewhere"]],
        ])
        let moved = h.editor.folders.first { $0.name == "B" }
        let elsewhere = h.editor.folders.first { $0.name == "Elsewhere" }
        #expect(moved?.parentFolderId == elsewhere?.id)
    }

    @Test func organizeRenamesAssetsAndFoldersByPath() async throws {
        let h = ToolHarness()
        let asset = h.makeAsset(name: "raw")
        _ = h.editor.createFolder(name: "Old", in: nil)

        let json = try await h.runOK("organize_media", args: [
            "renames": [
                ["item": asset.id, "name": "Hero take"],
                ["item": "Old", "name": "New"],
            ],
        ]) as? [String: Any]
        #expect(json?["renamed"] as? Int == 2)
        #expect(h.editor.mediaAssets.first { $0.id == asset.id }?.name == "Hero take")
        #expect(h.editor.folders.first?.name == "New")
    }

    @Test func organizeRejectsUnknownItemBeforeMutation() async throws {
        let h = ToolHarness()
        let asset = h.makeAsset(name: "keep")
        let result = await h.runRaw("organize_media", args: [
            "moves": [
                ["items": [asset.id], "into": "Refs"],
                ["items": ["ghost"], "into": "Refs"],
            ],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not an asset id"))
        #expect(h.editor.mediaAssets.first { $0.id == asset.id }?.folderId == nil)
        #expect(h.editor.folders.isEmpty)
    }

    @Test func organizeDeletesAssetsAndReportsRemovedClips() async throws {
        let h = ToolHarness()
        let asset = h.makeAsset(name: "used")
        h.editor.timeline.tracks = [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", mediaRef: asset.id, start: 0, duration: 60),
        ])]

        let json = try await h.runOK("organize_media", args: ["deletes": [asset.id]]) as? [String: Any]
        let deleted = json?["deleted"] as? [String: Any]
        #expect(deleted?["assets"] as? Int == 1)
        #expect(json?["clipsRemoved"] as? Int == 1)
        #expect(h.editor.mediaAssets.isEmpty)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
    }

    @Test func organizeDeletesFolderCascadeWithoutPhantomClipClaims() async throws {
        let h = ToolHarness()
        let refs = h.editor.createFolder(name: "Refs", in: nil)
        _ = h.editor.createFolder(name: "Sub", in: refs)

        let json = try await h.runOK("organize_media", args: ["deletes": ["Refs"]]) as? [String: Any]
        let deleted = json?["deleted"] as? [String: Any]
        #expect(deleted?["folders"] as? Int == 1)
        // Empty folder: no clips were touched, so no clipsRemoved claim.
        #expect(json?["clipsRemoved"] == nil)
        #expect(h.editor.folders.isEmpty)
    }

    @Test func organizeDeletesAcceptShortIdPrefixes() async throws {
        let h = ToolHarness()
        let asset = h.makeAsset(name: "prefixed")
        let json = try await h.runOK("organize_media", args: [
            "deletes": [String(asset.id.prefix(8))],
        ]) as? [String: Any]
        #expect((json?["deleted"] as? [String: Any])?["assets"] as? Int == 1)
        #expect(h.editor.mediaAssets.isEmpty)
    }

    @Test func organizeRequiresAtLeastOneOperation() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("organize_media")
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Nothing to do"))
    }

    // MARK: - ripple_delete_ranges

    /// Seconds are the default unit and convert through fps/trim/speed — the inspect_media path.
    @Test func rippleDeleteRangesConvertsSecondsThroughTrimAndSpeed() async throws {
        // 30fps, clip starts at frame 30, trimmed 60 source frames in. Source second 4.0 →
        // frame 30 + (120 - 60) = 90; second 5.0 → 30 + (150 - 60) = 120. Removing [90,120)
        // (30 frames) leaves the head [30,90) and slides the tail left to meet it.
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 30, duration: 300, trimStart: 60)]),
        ]))
        let result = await h.runRaw("ripple_delete_ranges", args: [
            "clipId": "c1",
            "ranges": [[4.0, 5.0]],
            "units": "seconds",
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let spans = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
            .map { [$0.startFrame, $0.endFrame] }
        #expect(spans == [[30, 90], [90, 300]])
    }

    @Test func rippleDeleteRangesDefaultsToFrames() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)]),
        ]))
        // No units → frames. These are project frames, the unit inspect_media(clipId) emits.
        let result = await h.runRaw("ripple_delete_ranges", args: [
            "clipId": "c1",
            "ranges": [[40, 50]],
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let spans = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
            .map { [$0.startFrame, $0.endFrame] }
        #expect(spans == [[0, 40], [40, 90]])
    }

    @Test func rippleDeleteRangesRejectsUnknownClip() async {
        let h = ToolHarness()
        let result = await h.runRaw("ripple_delete_ranges", args: [
            "clipId": "missing", "ranges": [[1.0, 2.0]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("Clip not found"))
    }

    @Test func rippleDeleteRangesRejectsRangesOutsideClip() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 30)]),
        ]))
        // Clip is 1s long at 30fps; a [10s, 11s] range can't overlap it.
        let result = await h.runRaw("ripple_delete_ranges", args: [
            "clipId": "c1", "ranges": [[10.0, 11.0]], "units": "seconds",
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("within clip"))
    }

    @Test func rippleDeleteRangesRejectsBadUnits() async {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 30)]),
        ]))
        let result = await h.runRaw("ripple_delete_ranges", args: [
            "clipId": "c1", "ranges": [[0.0, 0.5]], "units": "minutes",
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("units"))
    }

    @Test func rippleDeleteRangesReturnsResultingFragments() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 100)]),
        ]))
        let json = try await h.runOK("ripple_delete_ranges", args: [
            "clipId": "c1", "ranges": [[40, 50]],
        ]) as? [String: Any]
        #expect(json?["removedFrames"] as? Int == 10)
        let clips = json?["clips"] as? [[String: Any]] ?? []
        #expect(clips.count == 2)
        // Head keeps c1 at [0,40); tail is a new id at [40,90).
        #expect(clips.first?["id"] as? String == "c1")
        #expect(clips.first?["frames"] as? [Int] == [0, 40])
        #expect(clips.last?["frames"] as? [Int] == [40, 90])
        #expect(clips.last?["id"] as? String != "c1")
    }

    // MARK: - get_transcript

    @Test func getTranscriptEmptyTimelineReturnsNoWords() async throws {
        let h = ToolHarness()
        let json = try await h.runOK("get_transcript") as? [String: Any]
        #expect((json?["clips"] as? [Any])?.isEmpty == true)
        #expect(json?["timing"] as? String == "projectFrames")
    }

    @Test func getTranscriptSkipsClipsWithoutAudio() async throws {
        // A video clip whose asset has no audio contributes no words and isn't even transcribed.
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", mediaRef: "v", start: 0, duration: 100)]),
        ]))
        h.addAsset(id: "v", type: .video, hasAudio: false)
        let json = try await h.runOK("get_transcript") as? [String: Any]
        #expect((json?["clips"] as? [Any])?.isEmpty == true)
        #expect(json?["skipped"] == nil)
    }

    @Test func getTranscriptRejectsInvertedWindow() async {
        let h = ToolHarness()
        let result = await h.runRaw("get_transcript", args: ["startFrame": 100, "endFrame": 50])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("less than"))
    }
}

@Suite("ToolExecutor — set_clip_properties")
@MainActor
struct SetClipPropertiesTests {

    @Test func transformPreservesRotation() async {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: 60)
        clip.transform.rotation = 45.0
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))

        _ = await h.runRaw("set_clip_properties", args: [
            "clipIds": ["c1"],
            "transform": ["centerX": 0.3]
        ])

        let updated = h.editor.timeline.tracks[0].clips[0]
        // Bug: Transform(center:width:height:) defaults rotation to 0, discarding cur.rotation.
        #expect(updated.transform.rotation == 45.0)
    }

    @Test func updateTextCaptionGroupCollapsesToSummary() async {
        var clips: [Clip] = []
        for i in 0..<3 {
            var c = Fixtures.clip(id: "cap-\(i)", mediaRef: "text", mediaType: .text, start: i * 30, duration: 30)
            c.captionGroupId = "g1"
            c.textContent = "word\(i)"
            clips.append(c)
        }
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)]))

        let result = await h.runRaw("update_text", args: ["captionGroupId": "g1", "color": "#FF0000"])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let json = (try? JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8))) as? [String: Any]
        // ≥3 caption members collapse to the group summary, not an enumeration.
        #expect(json?["clips"] == nil)
        let group = (json?["captionGroups"] as? [[String: Any]])?.first
        #expect(group?["captionGroupId"] as? String == "g1")
        #expect(group?["clipCount"] as? Int == 3)
        #expect(group?["textPreview"] as? String == "word0 … word2")
    }

    @Test func updateTextCaptionGroupAcceptsRichTextStyleFields() async {
        var a = Fixtures.clip(id: "cap-a", mediaRef: "text", mediaType: .text, start: 0, duration: 30)
        var b = Fixtures.clip(id: "cap-b", mediaRef: "text", mediaType: .text, start: 30, duration: 30)
        a.captionGroupId = "captions"
        b.captionGroupId = "captions"
        a.textContent = "one"
        b.textContent = "two"
        a.textStyle = TextStyle()
        b.textStyle = TextStyle()
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [a, b])]))

        let result = await h.runRaw("update_text", args: [
            "captionGroupId": "captions",
            "alignment": "left",
            "borderColor": "#FFFFFF",
            "backgroundColor": "#00000080",
        ])

        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let json = (try? JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8))) as? [String: Any]
        #expect((json?["clips"] as? [[String: Any]])?.count == 2)
        let clips = h.editor.timeline.tracks[0].clips
        for clip in clips {
            #expect(clip.textStyle?.alignment == .left)
            #expect(clip.textStyle?.border.enabled == true)
            #expect(clip.textStyle?.border.color == TextStyle.RGBA(hex: "#FFFFFF"))
            #expect(clip.textStyle?.background.enabled == true)
            #expect(clip.textStyle?.background.color == TextStyle.RGBA(hex: "#00000080"))
        }
    }

    @Test func updateTextAnimationPreservesExistingHighlight() async {
        let highlight = TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1)
        var clip = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60)
        clip.textContent = "Title"
        clip.textAnimation = TextAnimation(preset: .highlightPop, perWordFrames: 12, highlight: highlight)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))

        let result = await h.runRaw("update_text", args: [
            "clipIds": ["title"],
            "animation": "wordPop",
        ])

        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        let animation = h.editor.timeline.tracks[0].clips[0].textAnimation
        #expect(animation?.preset == .wordPop)
        #expect(animation?.perWordFrames == 12)
        #expect(animation?.highlight == highlight)
    }

    @Test func updateTextContentClearsWordTimings() async {
        var clip = Fixtures.clip(id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60)
        clip.textContent = "old text"
        clip.textStyle = TextStyle()
        clip.wordTimings = [
            WordTiming(text: "old", startFrame: 0, endFrame: 30),
            WordTiming(text: "text", startFrame: 30, endFrame: 60),
        ]
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))

        let result = await h.runRaw("update_text", args: [
            "clipIds": ["title"],
            "content": "new text",
        ])

        #expect(result.isError == false, "\(ToolHarness.textOf(result))")
        #expect(h.editor.timeline.tracks[0].clips[0].wordTimings == nil)
    }
}
