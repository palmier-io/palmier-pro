import AppKit
import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("show_preview")
struct MCPPreviewAppTests {
    @Test @MainActor func listsToolMetaAndPreviewResource() async throws {
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        await MCPService.registerTools(on: server, executor: ToolExecutor(editor: EditorViewModel()))
        await MCPService.registerResources(on: server)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "preview-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "show_preview" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["mediaRef"] != nil)
            #expect(properties["mediaRefs"] != nil)
            #expect(tool._meta?["ui/resourceUri"]?.stringValue == MCPPreviewApp.resourceURI)
            #expect(
                tool._meta?["ui"]?.objectValue?["resourceUri"]?.stringValue
                    == MCPPreviewApp.resourceURI
            )

            let (resources, _) = try await client.listResources()
            let resource = try #require(resources.first { $0.uri == MCPPreviewApp.resourceURI })
            #expect(resource.mimeType == MCPPreviewApp.mimeType)

            let contents = try await client.readResource(uri: MCPPreviewApp.resourceURI)
            let html = try #require(contents.first?.text)
            #expect(html.contains("ui/initialize"))
            #expect(html.contains("size-changed"))
            #expect(html.contains("portrait"))
            #expect(html.contains("sc.items"))
            #expect(html.contains("generation"))
            #expect(html.contains("EventSource"))
            #expect(html.contains("tools/call"))
            #expect(html.contains("applyLook"))
            #expect(properties["clipId"] != nil)
            #expect(properties["look"] != nil)
            #expect(properties["startFrame"] != nil)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test @MainActor func registersPlayableURLAndServesBytes() async throws {
        let videoURL = try await FixtureVideo.write(
            scenes: [.init(rgb: (20, 180, 40), seconds: 0.4)],
            fps: 5,
            size: 32
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let editor = EditorViewModel()
        let asset = MediaAsset(url: videoURL, type: .video, name: "Green", duration: 0.4)
        asset.sourceWidth = 1080
        asset.sourceHeight = 1920
        editor.importMediaAsset(asset)
        let executor = ToolExecutor(editor: editor)

        let result = await executor.execute(name: "show_preview", args: ["mediaRef": asset.id])
        #expect(result.isError == false)
        let payload = try json(result)
        let previewURL = try #require(payload["videoUrl"] as? String)
        #expect(previewURL.hasPrefix("http://127.0.0.1:\(MCPService.port)/preview/"))
        #expect(payload["type"] as? String == "video")
        let item = try #require(result.structuredContent?.objectValue?["items"]?.arrayValue?.first?.objectValue)
        #expect(item["url"]?.stringValue == previewURL)
        #expect(item["width"]?.intValue == 1080)
        #expect(item["height"]?.intValue == 1920)
        #expect(result.mcpMeta?["ui/resourceUri"]?.stringValue == MCPPreviewApp.resourceURI)
        let mcp = result.toMCPResult()
        #expect(mcp.structuredContent?.objectValue?["items"]?.arrayValue?.count == 1)
        #expect(mcp._meta?["ui"]?.objectValue?["resourceUri"]?.stringValue == MCPPreviewApp.resourceURI)

        let token = try #require(URL(string: previewURL)?.lastPathComponent)
        let again = await executor.execute(name: "show_preview", args: ["mediaRef": asset.id])
        let againPayload = try json(again)
        #expect(againPayload["videoUrl"] as? String == previewURL)
        let port = UInt16.random(in: 49_500...64_000)
        let http = MCPHTTPServer(port: port) {
            let server = Server(name: "preview-http", version: "1.0.0")
            return MCPServerInstance(server: server) { _ in }
        }
        try await http.start()
        defer { Task { await http.stop() } }

        let served = URL(string: "http://127.0.0.1:\(port)/preview/\(token)")!
        let (data, response) = try await URLSession.shared.data(from: served)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(httpResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(httpResponse.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        let original = try Data(contentsOf: videoURL)
        #expect(data == original)

        var ranged = URLRequest(url: served)
        ranged.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        let (slice, rangeResponse) = try await URLSession.shared.data(for: ranged)
        let rangeHTTP = try #require(rangeResponse as? HTTPURLResponse)
        #expect(rangeHTTP.statusCode == 206)
        #expect(slice == original.prefix(16))
        #expect(rangeHTTP.value(forHTTPHeaderField: "Content-Range")?.contains("bytes 0-15/") == true)
    }

    @Test @MainActor func rejectsMissingAndUnsupportedAssets() async throws {
        let editor = EditorViewModel()
        let missing = MediaAsset(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mp4"),
            type: .video,
            name: "Gone",
            duration: 1
        )
        editor.importMediaAsset(missing)
        let lottie = MediaAsset(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("anim.json"),
            type: .lottie,
            name: "Anim",
            duration: 1
        )
        editor.importMediaAsset(lottie)
        let executor = ToolExecutor(editor: editor)

        let missingResult = await executor.execute(name: "show_preview", args: ["mediaRef": missing.id])
        #expect(missingResult.isError)
        #expect(ToolHarness.textOf(missingResult).contains("not on disk"))

        let unsupported = await executor.execute(name: "show_preview", args: ["mediaRef": lottie.id])
        #expect(unsupported.isError)
        #expect(ToolHarness.textOf(unsupported).contains("lottie"))

        let unknown = await executor.execute(name: "show_preview", args: ["mediaRef": UUID().uuidString])
        #expect(unknown.isError)

        let empty = await executor.execute(name: "show_preview", args: [:])
        #expect(empty.isError)
        #expect(ToolHarness.textOf(empty).contains("mediaRef"))
    }

    @Test @MainActor func showsMultipleImagesInOneResult() async throws {
        let firstURL = try writePNG(name: "one")
        let secondURL = try writePNG(name: "two")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let editor = EditorViewModel()
        let first = MediaAsset(url: firstURL, type: .image, name: "One", duration: 0)
        first.sourceWidth = 64
        first.sourceHeight = 64
        let second = MediaAsset(url: secondURL, type: .image, name: "Two", duration: 0)
        second.sourceWidth = 32
        second.sourceHeight = 48
        editor.importMediaAsset(first)
        editor.importMediaAsset(second)
        let executor = ToolExecutor(editor: editor)

        let result = await executor.execute(name: "show_preview", args: [
            "mediaRefs": [first.id, second.id],
        ])
        #expect(result.isError == false)
        let items = try #require(result.structuredContent?.objectValue?["items"]?.arrayValue)
        #expect(items.count == 2)
        #expect(items[0].objectValue?["type"]?.stringValue == "image")
        #expect(items[1].objectValue?["type"]?.stringValue == "image")
        #expect(items[1].objectValue?["height"]?.intValue == 48)
        let payload = try json(result)
        let listed = try #require(payload["items"] as? [[String: Any]])
        #expect(listed.count == 2)
        #expect((listed[0]["url"] as? String)?.contains("/preview/") == true)
        #expect((listed[1]["url"] as? String)?.contains("/preview/") == true)
    }

    @Test @MainActor func includesGenerationPromptAndPendingPlaceholder() async throws {
        let editor = EditorViewModel()
        let pending = MediaAsset(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString).mp4"),
            type: .video,
            name: "Pending clip",
            duration: 5
        )
        pending.generationInput = GenerationInput(
            prompt: "a paper-cutout campanile with a graduation cap",
            model: "unknown-model-id",
            duration: 5,
            aspectRatio: "9:16"
        )
        pending.generationStatus = .generating
        editor.importMediaAsset(pending)
        let executor = ToolExecutor(editor: editor)

        let result = await executor.execute(name: "show_preview", args: ["mediaRef": pending.id])
        #expect(result.isError == false)
        let item = try #require(result.structuredContent?.objectValue?["items"]?.arrayValue?.first?.objectValue)
        #expect(item["url"] == nil)
        #expect(item["eventsUrl"]?.stringValue?.contains("/preview/") == true)
        #expect(item["eventsUrl"]?.stringValue?.hasSuffix("/events") == true)
        let generation = try #require(item["generation"]?.objectValue)
        #expect(generation["prompt"]?.stringValue == "a paper-cutout campanile with a graduation cap")
        #expect(generation["model"]?.stringValue == "unknown-model-id")
        #expect(generation["aspectRatio"]?.stringValue == "9:16")
        #expect(generation["status"]?.stringValue == "generating")
    }

    @Test func unknownPreviewTokenIsNotFound() async throws {
        let port = UInt16.random(in: 49_500...64_000)
        let http = MCPHTTPServer(port: port) {
            let server = Server(name: "preview-http", version: "1.0.0")
            return MCPServerInstance(server: server) { _ in }
        }
        try await http.start()
        defer { Task { await http.stop() } }

        let url = URL(string: "http://127.0.0.1:\(port)/preview/\(UUID().uuidString)")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func fillsInWhenGenerationBecomesReady() async throws {
        let videoURL = try await FixtureVideo.write(
            scenes: [.init(rgb: (20, 180, 40), seconds: 0.4)],
            fps: 5,
            size: 32
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let handle = MCPPreviewStore.AssetHandle(
            mediaRef: UUID().uuidString,
            fileURL: nil,
            mimeType: "video/mp4",
            kind: .video,
            width: 32,
            height: 32,
            durationSeconds: 0.4,
            status: "generating",
            failure: nil
        )
        let token = await MCPPreviewStore.shared.upsert(handle)
        let port = UInt16.random(in: 49_500...64_000)
        let http = MCPHTTPServer(port: port) {
            let server = Server(name: "preview-http", version: "1.0.0")
            return MCPServerInstance(server: server) { _ in }
        }
        try await http.start()
        defer { Task { await http.stop() } }

        let eventsURL = URL(string: "http://127.0.0.1:\(port)/preview/\(token)/events")!
        let streamTask = Task {
            let (bytes, response) = try await URLSession.shared.bytes(from: eventsURL)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let jsonText = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard let payload = JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
                      payload["url"] != nil else { continue }
                return payload
            }
            throw CocoaError(.coderValueNotFound)
        }
        try await Task.sleep(for: .milliseconds(80))
        var ready = handle
        ready.fileURL = videoURL
        ready.status = nil
        await MCPPreviewStore.shared.publish(ready)
        let payload = try await streamTask.value
        #expect((payload["url"] as? String)?.contains("/preview/\(token)") == true)
        #expect(payload["type"] as? String == "video")
    }

    @Test @MainActor func variantGridBindsKeepToClipId() async throws {
        let firstURL = try writePNG(name: "keep-a")
        let secondURL = try writePNG(name: "keep-b")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let editor = EditorViewModel()
        let first = MediaAsset(url: firstURL, type: .image, name: "A", duration: 0)
        let second = MediaAsset(url: secondURL, type: .image, name: "B", duration: 0)
        editor.importMediaAsset(first)
        editor.importMediaAsset(second)
        var timeline = Timeline()
        timeline.tracks = [Fixtures.videoTrack(clips: [
            Fixtures.clip(mediaRef: first.id, start: 0, duration: 30),
        ])]
        editor.timeline = timeline
        let clipId = editor.timeline.tracks[0].clips[0].id
        let executor = ToolExecutor(editor: editor)

        let result = await executor.execute(name: "show_preview", args: [
            "mediaRefs": [first.id, second.id],
            "clipId": clipId,
        ])
        #expect(result.isError == false)
        #expect(result.structuredContent?.objectValue?["clipId"]?.stringValue == clipId)
        let items = try #require(result.structuredContent?.objectValue?["items"]?.arrayValue)
        #expect(items.count == 2)
        #expect(items[1].objectValue?["canKeep"]?.boolValue == true)
        #expect(items[1].objectValue?["clipId"]?.stringValue == clipId)
        #expect(items[0].objectValue?["canPlace"]?.boolValue == true)
    }

    @Test @MainActor func cutWindowServesCompositedFrames() async throws {
        let fixture = try await makeTimelineFixture()
        defer { cleanupFixture(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)
        let result = await executor.execute(name: "show_preview", args: [
            "startFrame": 0,
            "endFrame": 10,
            "maxFrames": 3,
        ])
        #expect(result.isError == false)
        #expect(result.structuredContent?.objectValue?["intent"]?.stringValue == "cut")
        #expect(result.structuredContent?.objectValue?["mutated"]?.boolValue == false)
        let frames = try #require(result.structuredContent?.objectValue?["frames"]?.arrayValue)
        #expect(frames.count == 3)
        let url = try #require(frames[0].objectValue?["url"]?.stringValue)
        let token = try #require(URL(string: url)?.lastPathComponent)
        let port = UInt16.random(in: 49_500...64_000)
        let http = MCPHTTPServer(port: port) {
            let server = Server(name: "preview-http", version: "1.0.0")
            return MCPServerInstance(server: server) { _ in }
        }
        try await http.start()
        defer { Task { await http.stop() } }
        let served = URL(string: "http://127.0.0.1:\(port)/preview/blob/\(token)")!
        let (data, response) = try await URLSession.shared.data(from: served)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(data.count > 32)
        #expect(fixture.editor.timeline.tracks[0].clips.count == 1)
    }

    @Test @MainActor func lookPreviewDoesNotMutateTimeline() async throws {
        let fixture = try await makeTimelineFixture()
        defer { cleanupFixture(fixture) }
        var caption = Fixtures.clip(
            mediaRef: "",
            mediaType: .text,
            start: 0,
            duration: 10
        )
        caption.textContent = "Hello"
        caption.textStyle = .caption
        caption.captionGroupId = "g1"
        var timeline = fixture.editor.timeline
        timeline.tracks.insert(Fixtures.videoTrack(clips: [caption]), at: 0)
        fixture.editor.timeline = timeline
        let before = fixture.editor.timeline
        let executor = ToolExecutor(editor: fixture.editor)
        let result = await executor.execute(name: "show_preview", args: [
            "startFrame": 0,
            "endFrame": 10,
            "look": [
                "style": ["fontSize": 72.0],
                "sampleText": "Preview look",
            ],
        ])
        #expect(result.isError == false)
        #expect(result.structuredContent?.objectValue?["intent"]?.stringValue == "look")
        #expect(result.structuredContent?.objectValue?["mutated"]?.boolValue == false)
        #expect(result.structuredContent?.objectValue?["look"]?.objectValue?["mode"]?.stringValue == "restyle")
        let apply = try #require(result.structuredContent?.objectValue?["applyLook"]?.arrayValue)
        #expect(apply.first?.objectValue?["name"]?.stringValue == "update_text")
        #expect(fixture.editor.timeline == before)
        #expect(fixture.editor.timeline.tracks[0].clips[0].textStyle?.fontSize == TextStyle.caption.fontSize)
    }

    @Test @MainActor func rejectsMixedLookAndMedia() async throws {
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor)
        let result = await executor.execute(name: "show_preview", args: [
            "mediaRef": UUID().uuidString,
            "look": ["sampleText": "Hi"],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("look cannot be combined"))
    }

    @Test func previewContextReturnsJSON() async throws {
        let port = UInt16.random(in: 49_500...64_000)
        let http = MCPHTTPServer(port: port) {
            let server = Server(name: "preview-http", version: "1.0.0")
            return MCPServerInstance(server: server) { _ in }
        }
        try await http.start()
        defer { Task { await http.stop() } }
        let url = URL(string: "http://127.0.0.1:\(port)/preview/context")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(JSONSerialization.jsonObject(with: data) is [String: Any])
    }

    private func json(_ result: ToolResult) throws -> [String: Any] {
        guard case .text(let text) = result.content.first else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func writePNG(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-\(name)-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }

    private struct TimelineFixture {
        let editor: EditorViewModel
        let videoURL: URL
    }

    private func makeTimelineFixture() async throws -> TimelineFixture {
        let videoURL = try await FixtureVideo.write(
            scenes: [.init(rgb: (240, 20, 20), seconds: 1)],
            fps: 5,
            size: 64
        )
        let editor = EditorViewModel()
        let source = MediaAsset(url: videoURL, type: .video, name: "Red", duration: 1)
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
        return TimelineFixture(editor: editor, videoURL: videoURL)
    }

    private func cleanupFixture(_ fixture: TimelineFixture) {
        let videoURL = fixture.videoURL
        Task.detached {
            try? FileManager.default.removeItem(at: videoURL)
        }
    }
}
