import CoreGraphics
import Foundation
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
            #expect(images(preview.content).count == 2)
            #expect(try json(text(preview.content))["status"] as? String == "preview")
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
            let clip = try #require(fixture.editor.clipFor(id: fixture.clipId))
            #expect(clip.crop == Crop(left: 0.5, top: 0, right: 0, bottom: 0.5))
            #expect(clip.cropTrack == nil)

            let timeline = try json(text(
                try await client.callTool(name: "get_timeline").content
            ))
            let tracks = try #require(timeline["tracks"] as? [[String: Any]])
            let clips = try #require(tracks.first?["clips"] as? [[String: Any]])
            let crop = try #require(clips.first?["crop"] as? [String: Any])
            #expect(crop["left"] as? Double == 0.5)
            #expect(crop["bottom"] as? Double == 0.5)

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

    private func images(_ content: [Tool.Content]) -> [String] {
        content.compactMap { item in
            if case .image(let data, _, _, _) = item { return data }
            return nil
        }
    }
}
