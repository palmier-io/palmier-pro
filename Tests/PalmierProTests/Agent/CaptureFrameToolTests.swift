import AVFoundation
import CoreImage
import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("capture_frame", .serialized)
@MainActor
struct CaptureFrameToolTests {
    @Test func MCPDiscoveryCaptureReadbackAndUndo() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: ToolExecutor(editor: fixture.editor))
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "capture-frame-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "capture_frame" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["timelineFrame"]?.objectValue?["type"]?.stringValue == "integer")
            #expect(properties["mediaRef"]?.objectValue?["type"]?.stringValue == "string")
            #expect(properties["sourceSeconds"]?.objectValue?["type"]?.stringValue == "number")

            let sourceCapture = try await client.callTool(name: "capture_frame", arguments: [
                "mediaRef": .string(fixture.source.id),
                "sourceSeconds": .double(fixture.source.duration),
                "name": .string("Final source frame"),
            ])
            let sourceReceipt = try json(text(sourceCapture.content))
            let sourceRef = try #require(sourceReceipt["mediaRef"] as? String)
            #expect(sourceReceipt["name"] as? String == "Final source frame")
            #expect(fixture.editor.mediaAssets.first { $0.id.hasPrefix(sourceRef) }?.thumbnail != nil)
            let sourceImage = try imageData(try await client.callTool(
                name: "inspect_media",
                arguments: ["mediaRef": .string(sourceRef)]
            ).content)

            let timelineCapture = try await client.callTool(
                name: "capture_frame",
                arguments: ["timelineFrame": .int(0)]
            )
            let timelineRef = try #require(try json(text(timelineCapture.content))["mediaRef"] as? String)
            let timelineImage = try imageData(try await client.callTool(
                name: "inspect_media",
                arguments: ["mediaRef": .string(timelineRef)]
            ).content)
            let sourceColor = try await Self.averageRGB(sourceImage)
            let timelineColor = try await Self.averageRGB(timelineImage)
            #expect(sourceColor.blue > sourceColor.red)
            #expect(timelineColor.red > timelineColor.blue)

            let placement = try await client.callTool(name: "add_clips", arguments: [
                "entries": .array([.object([
                    "mediaRef": .string(timelineRef),
                    "startFrame": .int(10),
                ])]),
            ])
            _ = try json(text(placement.content))
            _ = try await client.callTool(name: "undo")

            _ = try await client.callTool(name: "undo")
            let afterFirstUndo = try await mediaIds(client, ids: [sourceRef, timelineRef])
            #expect(afterFirstUndo == Set([sourceRef]))
            _ = try await client.callTool(name: "undo")
            #expect(try await mediaIds(client, ids: [sourceRef, timelineRef]).isEmpty)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func invalidCancelledAndClosingRequestsDoNotCreateAssets() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)
        let originalIds = fixture.editor.mediaAssets.map(\.id)

        let invalidResults = await [
            executor.execute(name: "capture_frame", args: [
                "timelineFrame": 0,
                "mediaRef": fixture.source.id,
                "sourceSeconds": 0,
            ]),
            executor.execute(name: "capture_frame", args: ["timelineFrame": "0"]),
            executor.execute(name: "capture_frame", args: [
                "mediaRef": fixture.source.id,
                "sourceSeconds": 3.0,
            ]),
            executor.execute(name: "capture_frame", args: ["timelineFrame": 10]),
        ]
        #expect(invalidResults.allSatisfy { $0.isError })

        let cancelled = Task { @MainActor in
            try await fixture.editor.captureFrameToMedia(
                source: .media(mediaRef: fixture.source.id, sourceSeconds: 0)
            )
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        await fixture.editor.projectPackageCoordinator.beginClosing()
        await #expect(throws: CancellationError.self) {
            try await fixture.editor.captureFrameToMedia(
                source: .media(mediaRef: fixture.source.id, sourceSeconds: 0)
            )
        }
        fixture.editor.projectPackageCoordinator.cancelClosing()
        #expect(fixture.editor.mediaAssets.map(\.id) == originalIds)
    }

    @Test func sourceSecondsUseVideoTrackTimeRange() throws {
        let timeRange = CMTimeRange(
            start: CMTime(value: 5, timescale: 5),
            duration: CMTime(value: 10, timescale: 5)
        )
        let request = try FrameCaptureRenderer.sourceFrameRequest(
            sourceSeconds: 2,
            timeRange: timeRange,
            minimumFrameDuration: CMTime(value: 1, timescale: 5)
        )
        #expect(request.capturesLastFrame)
        #expect(request.time == CMTime(value: 14, timescale: 5))
    }

    @Test func sourcePreviewAndCaptureUseSameTrackRelativeTime() throws {
        let trackStart = CMTime(value: 30, timescale: 30)
        let previewTime = SourceMediaTimebase.absoluteTime(
            relativeFrame: 30,
            fps: 30,
            trackStart: trackStart
        )
        let capture = try FrameCaptureRenderer.sourceFrameRequest(
            sourceSeconds: 1,
            timeRange: CMTimeRange(start: trackStart, duration: CMTime(value: 300, timescale: 30)),
            minimumFrameDuration: CMTime(value: 1, timescale: 30)
        )
        #expect(previewTime == capture.time)
        #expect(SourceMediaTimebase.relativeFrame(
            absoluteTime: previewTime,
            fps: 30,
            trackStart: trackStart
        ) == 30)
    }

    @Test func sourcePreviewLoadUsesLiveScrubFrameBeforePlaying() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let engine = VideoEngine(editor: fixture.editor)
        fixture.editor.videoEngine = engine
        defer {
            engine.pause()
            engine.teardown()
            fixture.editor.videoEngine = nil
        }

        fixture.editor.openPreviewTab(for: fixture.source)
        let load = try #require(engine.sourcePreviewTask)
        fixture.editor.seekSourceToFrame(5, mode: .interactiveScrub)
        engine.play()
        await load.value

        #expect(engine.sourcePreviewTask == nil)
        #expect(engine.player.currentItem != nil)
        #expect(engine.player.currentTime().seconds >= 0.9)
        #expect(engine.player.rate > 0)
    }

    @Test func sourcePreviewTimingFailureDoesNotInstallOrPlayItem() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let missing = MediaAsset(
            url: fixture.root.appendingPathComponent("missing.mov"),
            type: .video,
            name: "Missing",
            duration: 1
        )
        fixture.editor.importMediaAsset(missing)
        let engine = VideoEngine(editor: fixture.editor)
        fixture.editor.videoEngine = engine
        defer {
            engine.teardown()
            fixture.editor.videoEngine = nil
        }

        fixture.editor.openPreviewTab(for: missing)
        let load = try #require(engine.sourcePreviewTask)
        engine.play()
        await load.value

        #expect(engine.sourcePreviewTask == nil)
        #expect(engine.player.currentItem == nil)
        #expect(!fixture.editor.isPlaying)
    }

    @Test func staleSourcePreviewLoadPreservesDeferredPlayback() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let engine = VideoEngine(editor: fixture.editor)
        fixture.editor.videoEngine = engine
        defer {
            engine.teardown()
            fixture.editor.videoEngine = nil
        }

        fixture.editor.openPreviewTab(for: fixture.source)
        let load = try #require(engine.sourcePreviewTask)
        engine.play()
        fixture.source.url = fixture.root.appendingPathComponent("replacement.mov")
        await load.value

        #expect(engine.sourcePreviewTask == nil)
        #expect(fixture.editor.isPlaying)
        #expect(engine.player.rate == 0)

        fixture.source.url = fixture.videoURL
        engine.previewAsset(fixture.source)
        let successor = try #require(engine.sourcePreviewTask)
        await successor.value

        #expect(engine.sourcePreviewTask == nil)
        #expect(fixture.editor.isPlaying)
        #expect(engine.player.rate > 0)
    }

    private struct Fixture {
        let editor: EditorViewModel
        let root: URL
        let videoURL: URL
        let source: MediaAsset
        let undoManager: UndoManager
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-frame-\(UUID().uuidString)", isDirectory: true)
        let videoURL = try await FixtureVideo.write(scenes: [
            .init(rgb: (240, 20, 20), seconds: 1),
            .init(rgb: (20, 20, 240), seconds: 1),
        ], fps: 5, size: 64)
        let editor = EditorViewModel()
        editor.projectURL = root.appendingPathComponent("Capture.palmier", isDirectory: true)
        let source = MediaAsset(url: videoURL, type: .video, name: "Two colors", duration: 2)
        source.sourceWidth = 64
        source.sourceHeight = 64
        source.sourceFPS = 5
        source.hasAudio = false
        editor.importMediaAsset(source)
        var timeline = Timeline()
        timeline.fps = 5
        timeline.width = 64
        timeline.height = 64
        timeline.tracks = [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: source.id, start: 0, duration: 10),
        ])]
        editor.timeline = timeline
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)
        return Fixture(editor: editor, root: root, videoURL: videoURL, source: source, undoManager: undoManager)
    }

    private func cleanup(_ fixture: Fixture) {
        let root = fixture.root
        let videoURL = fixture.videoURL
        Task.detached {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: videoURL)
        }
    }

    private func mediaIds(_ client: Client, ids: [String]) async throws -> Set<String> {
        let result = try await client.callTool(name: "get_media", arguments: [
            "ids": .array(ids.map(Value.string)),
        ])
        let assets = try #require(try json(text(result.content))["assets"] as? [[String: Any]])
        return Set(assets.compactMap { $0["id"] as? String })
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func imageData(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .image(let data, _, _, _) = item { return data }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    @concurrent
    private static func averageRGB(_ base64: String) async throws -> (red: UInt8, blue: UInt8) {
        let data = try #require(Data(base64Encoded: base64))
        let image = try #require(CIImage(data: data))
        let average = image.applyingFilter(
            "CIAreaAverage",
            parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)]
        )
        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(
            average,
            toBitmap: &rgba,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return (rgba[0], rgba[2])
    }
}
