import Foundation
import MCP
import Testing

@testable import PalmierPro

@Suite("MCP — text scale")
@MainActor
struct MCPTextScaleTests {
    @Test func discoveryUpdateReadbackValidationAndUndo() async throws {
        var clip = Fixtures.clip(
            id: "text-1", mediaRef: "", mediaType: .text, start: 0, duration: 90
        )
        clip.textContent = "Stretch"
        var originalStyle = TextStyle()
        originalStyle.widthScale = 0.85
        originalStyle.heightScale = 1.1
        clip.textStyle = originalStyle
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "text-scale-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let updateText = try #require(tools.first { $0.name == "update_text" })
            let properties = try #require(updateText.inputSchema.objectValue?["properties"]?.objectValue)
            let style = try #require(properties["style"]?.objectValue?["properties"]?.objectValue)
            #expect(style["widthScale"]?.objectValue?["minimum"]?.doubleValue == 0.1)
            #expect(style["widthScale"]?.objectValue?["maximum"]?.intValue == 10)
            #expect(style["heightScale"]?.objectValue?["minimum"]?.doubleValue == 0.1)
            #expect(style["heightScale"]?.objectValue?["maximum"]?.intValue == 10)

            let update = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "style": .object([
                    "widthScale": .double(1.5),
                    "heightScale": .double(0.75),
                ]),
            ])
            #expect(update.isError != true)
            let updatedStyle = try await textStyle(client: client, clipId: clip.id)
            #expect((updatedStyle["widthScale"] as? NSNumber)?.doubleValue == 1.5)
            #expect((updatedStyle["heightScale"] as? NSNumber)?.doubleValue == 0.75)

            let invalid = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "style": .object(["widthScale": .double(0)]),
            ])
            #expect(invalid.isError == true)
            let afterInvalid = try await textStyle(client: client, clipId: clip.id)
            #expect((afterInvalid["widthScale"] as? NSNumber)?.doubleValue == 1.5)

            let undo = try await client.callTool(name: "undo")
            #expect(undo.isError != true)
            let restoredStyle = try await textStyle(client: client, clipId: clip.id)
            #expect((restoredStyle["widthScale"] as? NSNumber)?.doubleValue == 0.85)
            #expect((restoredStyle["heightScale"] as? NSNumber)?.doubleValue == 1.1)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func textStyle(client: Client, clipId: String) async throws -> [String: Any] {
        let result = try await client.callTool(name: "get_timeline")
        let payload = try json(text(result.content))
        let tracks = try #require(payload["tracks"] as? [[String: Any]])
        let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
        let clip = try #require(clips.first { $0["id"] as? String == clipId })
        return try #require(clip["textStyle"] as? [String: Any])
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
