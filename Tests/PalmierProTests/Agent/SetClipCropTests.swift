import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("static crop Agent tool", .serialized)
@MainActor
struct SetClipCropTests {
    @Test func MCPDiscoveryMutationReadbackValidationAndUndo() async throws {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: 30)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)

        let server = Server(
            name: "static-crop-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: ToolExecutor(editor: editor))
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "static-crop-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "set_clip_properties" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            let crop = try #require(properties["crop"]?.objectValue)
            #expect(crop["type"]?.stringValue == "object")
            let cropFields = try #require(crop["properties"]?.objectValue)
            for key in ["left", "top", "right", "bottom"] {
                #expect(cropFields[key]?.objectValue?["type"]?.stringValue == "number")
            }

            let mutation = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "crop": .object([
                    "left": .double(0.2),
                    "top": .double(0.1),
                    "right": .double(0.15),
                    "bottom": .double(0.05),
                ]),
            ])
            #expect(mutation.isError != true)
            let receipt = try json(text(mutation.content))
            let changed = try #require(receipt["clips"] as? [[String: Any]])
            let receiptCrop = try #require(changed.first?["crop"] as? [String: Any])
            #expect(receiptCrop["left"] as? Double == 0.2)
            #expect(receiptCrop["top"] as? Double == 0.1)
            #expect(receiptCrop["right"] as? Double == 0.15)
            #expect(receiptCrop["bottom"] as? Double == 0.05)

            let timeline = try json(text(try await client.callTool(name: "get_timeline").content))
            let timelineCrop = try #require(clipCrop(in: timeline))
            #expect(timelineCrop["left"] as? Double == 0.2)
            #expect(timelineCrop["top"] as? Double == 0.1)

            let invalid = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "crop": .object(["left": .double(0.5), "right": .double(0.5)]),
            ])
            #expect(invalid.isError == true)
            #expect(editor.clipFor(id: clip.id)?.crop.left == 0.2)

            let undo = try await client.callTool(name: "undo")
            #expect(undo.isError != true)
            let restored = try json(text(try await client.callTool(name: "get_timeline").content))
            #expect(clipCrop(in: restored) == nil)
            #expect(editor.clipFor(id: clip.id)?.crop.isIdentity == true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func clipCrop(in timeline: [String: Any]) -> [String: Any]? {
        let tracks = timeline["tracks"] as? [[String: Any]]
        let clips = tracks?.first?["clips"] as? [[String: Any]]
        return clips?.first?["crop"] as? [String: Any]
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
}
