import CoreGraphics
import Foundation
import ImageIO
import MCP
import Testing
@testable import PalmierPro

@Suite("crop_to_subject", .serialized)
@MainActor
struct CropToSubjectToolTests {
    @Test func MCPDiscoveryPreviewApplyReadbackAndUndo() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: ToolExecutor(editor: fixture.editor))
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "crop-to-subject-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "crop_to_subject" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["prompt"]?.objectValue?["type"]?.stringValue == "string")
            #expect(properties["bounds"]?.objectValue?["type"]?.stringValue == "object")
            #expect(properties["apply"]?.objectValue?["type"]?.stringValue == "boolean")

            let guide = try await client.callTool(name: "crop_to_subject", arguments: [
                "clipId": .string(fixture.clipId),
                "prompt": .string("the blue picture-in-picture"),
            ])
            #expect(images(guide.content).count == 1)
            let guideReceipt = try json(text(guide.content))
            #expect(guideReceipt["status"] as? String == "needsBounds")
            #expect(guideReceipt["atFrame"] as? Int == 15)
            #expect(guideReceipt["imageRoles"] as? [String] == ["fullGrid"])
            let guideGrid = try #require(guideReceipt["grid"] as? [String: Any])
            #expect(guideGrid["scope"] as? String == "full")
            #expect((guideGrid["xEdges"] as? [Double])?.count == 11)
            #expect(fixture.editor.clipFor(id: fixture.clipId)?.crop == Crop())
            #expect(fixture.undoManager.canUndo == false)

            let bounds: [String: Value] = [
                "left": .double(0.5),
                "top": .double(0),
                "right": .double(1),
                "bottom": .double(0.5),
            ]
            let preview = try await client.callTool(name: "crop_to_subject", arguments: [
                "clipId": .string(fixture.clipId),
                "prompt": .string("the blue picture-in-picture"),
                "bounds": .object(bounds),
            ])
            let previewImages = images(preview.content)
            #expect(previewImages.count == 3)
            let previewReceipt = try json(text(preview.content))
            #expect(previewReceipt["status"] as? String == "preview")
            #expect(previewReceipt["imageRoles"] as? [String] == [
                "fullContext", "refinementGrid", "cropPreview",
            ])
            let previewGrid = try #require(previewReceipt["grid"] as? [String: Any])
            #expect(previewGrid["scope"] as? String == "refinement")
            let xEdges = try #require(previewGrid["xEdges"] as? [Double])
            let yEdges = try #require(previewGrid["yEdges"] as? [Double])
            #expect(xEdges == [0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1])
            #expect(yEdges == [0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5])
            #expect(try imageSize(previewImages[0]) == CGSize(width: 200, height: 120))
            #expect(try imageSize(previewImages[1]) == CGSize(width: 100, height: 60))
            #expect(try imageSize(previewImages[2]) == CGSize(width: 100, height: 60))
            let previewRGB = try averageRGB(previewImages[2])
            #expect(previewRGB.blue > 0.7)
            #expect(previewRGB.blue > previewRGB.red * 4)
            #expect(fixture.editor.clipFor(id: fixture.clipId)?.crop == Crop())
            #expect(fixture.undoManager.canUndo == false)

            fixture.editor.timeline.tracks[0].clips[0].cropTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: Crop(left: 0.1)),
                Keyframe(frame: 29, value: Crop(right: 0.1)),
            ])
            let applied = try await client.callTool(name: "crop_to_subject", arguments: [
                "clipId": .string(fixture.clipId),
                "prompt": .string("the blue picture-in-picture"),
                "bounds": .object(bounds),
                "apply": .bool(true),
            ])
            let receipt = try json(text(applied.content))
            #expect(receipt["status"] as? String == "applied")
            #expect(receipt["clearedCropKeyframes"] as? Bool == true)
            #expect(images(applied.content).count == 3)
            let clip = try #require(fixture.editor.clipFor(id: fixture.clipId))
            #expect(clip.crop == Crop(left: 0.5, top: 0, right: 0, bottom: 0.5))
            #expect(clip.layoutCrop == nil)
            #expect(clip.cropTrack == nil)

            let timeline = try json(text(
                try await client.callTool(name: "get_timeline").content
            ))
            let tracks = try #require(timeline["tracks"] as? [[String: Any]])
            let clips = try #require(tracks.first?["clips"] as? [[String: Any]])
            let crop = try #require(clips.first?["crop"] as? [String: Any])
            #expect(crop["left"] as? Double == 0.5)
            #expect(crop["bottom"] as? Double == 0.5)

            let unchanged = try await client.callTool(name: "crop_to_subject", arguments: [
                "clipId": .string(fixture.clipId),
                "prompt": .string("the blue picture-in-picture"),
                "bounds": .object(bounds),
                "apply": .bool(true),
            ])
            #expect(try json(text(unchanged.content))["status"] as? String == "unchanged")

            _ = try await client.callTool(name: "undo")
            let restored = try #require(fixture.editor.clipFor(id: fixture.clipId))
            #expect(restored.crop == Crop())
            #expect(restored.cropTrack?.isActive == true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func videoInspectionUsesTrimAndSpeedSourceTime() async throws {
        let url = try await FixtureVideo.write(
            scenes: [
                .init(rgb: (255, 0, 0), seconds: 1),
                .init(rgb: (0, 0, 255), seconds: 1),
            ],
            fps: 10,
            size: 64
        )
        defer { Task.detached { try? FileManager.default.removeItem(at: url) } }
        let media = MediaAsset(url: url, type: .video, name: "Timing", duration: 2)
        media.sourceWidth = 64
        media.sourceHeight = 64
        var clip = Fixtures.clip(
            id: "video-crop",
            mediaRef: media.id,
            mediaType: .video,
            start: 0,
            duration: 10
        )
        clip.trimStartFrame = 5
        var timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        timeline.fps = 10
        timeline.width = 64
        timeline.height = 64
        let editor = EditorViewModel()
        editor.timeline = timeline
        editor.importMediaAsset(media)

        let result = await ToolExecutor(editor: editor).execute(name: "crop_to_subject", args: [
            "clipId": clip.id,
            "prompt": "blue frame",
            "atFrame": 7,
            "bounds": ["left": 0.0, "top": 0.0, "right": 1.0, "bottom": 1.0],
        ])

        #expect(result.isError == false)
        let receipt = try json(text(result.content))
        let actual = try #require(receipt["actualSourceSeconds"] as? Double)
        #expect(abs(actual - 1.2) < 0.11)
        let rgb = try averageRGB(try #require(images(result.content).last))
        #expect(rgb.blue > rgb.red * 4)
    }

    @Test func invalidBoundsAndFrameDoNotMutate() async throws {
        let fixture = try await makeFixture()
        defer { cleanup(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)

        let requests: [[String: Any]] = [
            [
                "clipId": fixture.clipId,
                "prompt": "subject",
                "bounds": ["left": 0.8, "top": 0.1, "right": 0.2, "bottom": 0.9],
                "apply": true,
            ],
            [
                "clipId": fixture.clipId,
                "prompt": "subject",
                "bounds": ["left": 0.1, "top": 0.1, "right": 0.12, "bottom": 0.9],
                "apply": true,
            ],
            [
                "clipId": fixture.clipId,
                "prompt": "subject",
                "atFrame": 30,
            ],
            [
                "clipId": fixture.clipId,
                "prompt": " ",
            ],
        ]

        for request in requests {
            let result = await executor.execute(name: "crop_to_subject", args: request)
            #expect(result.isError)
        }

        let cancelled = Task {
            await executor.execute(name: "crop_to_subject", args: [
                "clipId": fixture.clipId,
                "prompt": "subject",
                "bounds": ["left": 0.5, "top": 0.0, "right": 1.0, "bottom": 0.5],
                "apply": true,
            ])
        }
        cancelled.cancel()
        #expect((await cancelled.value).isError)
        #expect(fixture.editor.clipFor(id: fixture.clipId)?.crop == Crop())
        #expect(fixture.undoManager.canUndo == false)
    }

    private struct Fixture {
        let editor: EditorViewModel
        let root: URL
        let clipId: String
        let undoManager: UndoManager
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crop-to-subject-\(UUID().uuidString)", isDirectory: true)
        let imageURL = root.appendingPathComponent("screen.png")
        try await Self.writeFixtureImage(to: imageURL)

        let media = MediaAsset(
            url: imageURL,
            type: .image,
            name: "Stream screen",
            duration: 1
        )
        media.sourceWidth = 200
        media.sourceHeight = 120

        let clipId = "crop-clip"
        var timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(
                    id: clipId,
                    mediaRef: media.id,
                    mediaType: .image,
                    start: 0,
                    duration: 30
                ),
            ]),
        ])
        timeline.width = 200
        timeline.height = 120

        let editor = EditorViewModel()
        editor.timeline = timeline
        editor.importMediaAsset(media)
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)
        return Fixture(
            editor: editor,
            root: root,
            clipId: clipId,
            undoManager: undoManager
        )
    }

    @concurrent
    private static func writeFixtureImage(to url: URL) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 200,
            height: 120,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        context.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 100, y: 60, width: 100, height: 60))
        let image = try #require(context.makeImage())
        let data = try #require(ImageEncoder.encodePNG(image))
        try data.write(to: url, options: .atomic)
    }

    private func cleanup(_ fixture: Fixture) {
        let root = fixture.root
        Task.detached {
            try? FileManager.default.removeItem(at: root)
        }
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

    private func text(_ content: [ToolResult.Block]) throws -> String {
        for item in content {
            if case .text(let text) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private func images(_ content: [Tool.Content]) -> [String] {
        content.compactMap { item in
            if case .image(let data, _, _, _) = item { return data }
            return nil
        }
    }

    private func images(_ content: [ToolResult.Block]) -> [String] {
        content.compactMap { item in
            if case .image(let data, _) = item { return data }
            return nil
        }
    }

    private func imageSize(_ base64: String) throws -> CGSize {
        let image = try decodedImage(base64)
        return CGSize(width: image.width, height: image.height)
    }

    private func averageRGB(_ base64: String) throws -> (red: Double, green: Double, blue: Double) {
        let image = try decodedImage(base64)
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        return (
            Double(bytes[0]) / 255,
            Double(bytes[1]) / 255,
            Double(bytes[2]) / 255
        )
    }

    private func decodedImage(_ base64: String) throws -> CGImage {
        let data = try #require(Data(base64Encoded: base64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
