import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("image adjustment Agent tool", .serialized)
@MainActor
struct EdgeRoundingToolTests {
    @Test func MCPDiscoveryMutationReadbackValidationAndUndo() async throws {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: 30)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)

        let server = Server(
            name: "edge-rounding-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: ToolExecutor(editor: editor))
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "edge-rounding-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "set_clip_properties" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["edgeRounding"]?.objectValue?["type"]?.stringValue == "number")
            #expect(properties["edgeSoftness"]?.objectValue?["type"]?.stringValue == "number")

            let mutation = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "edgeRounding": .double(0.4),
                "edgeSoftness": .double(0.25),
            ])
            #expect(mutation.isError != true)
            let receipt = try json(text(mutation.content))
            let changed = try #require(receipt["clips"] as? [[String: Any]])
            #expect(changed.first?["edgeRounding"] as? Double == 0.4)
            #expect(changed.first?["edgeSoftness"] as? Double == 0.25)

            let timeline = try json(text(try await client.callTool(name: "get_timeline").content))
            #expect(edgeRounding(in: timeline) == 0.4)
            #expect(edgeSoftness(in: timeline) == 0.25)

            let invalid = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "edgeSoftness": .double(1.1),
            ])
            #expect(invalid.isError == true)
            #expect(editor.clipFor(id: clip.id)?.edgeRounding == 0.4)
            #expect(editor.clipFor(id: clip.id)?.edgeSoftness == 0.25)

            let undo = try await client.callTool(name: "undo")
            #expect(undo.isError != true)
            let restored = try json(text(try await client.callTool(name: "get_timeline").content))
            #expect(edgeRounding(in: restored) == nil)
            #expect(edgeSoftness(in: restored) == nil)
            #expect(editor.clipFor(id: clip.id)?.edgeRounding == 0)
            #expect(editor.clipFor(id: clip.id)?.edgeSoftness == 0)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func edgeRounding(in timeline: [String: Any]) -> Double? {
        let tracks = timeline["tracks"] as? [[String: Any]]
        let clips = tracks?.first?["clips"] as? [[String: Any]]
        return clips?.first?["edgeRounding"] as? Double
    }

    private func edgeSoftness(in timeline: [String: Any]) -> Double? {
        let tracks = timeline["tracks"] as? [[String: Any]]
        let clips = tracks?.first?["clips"] as? [[String: Any]]
        return clips?.first?["edgeSoftness"] as? Double
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
