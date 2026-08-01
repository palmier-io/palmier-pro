import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP custom aspect ratio", .serialized)
@MainActor
struct MCPCustomAspectRatioTests {
    @Test func discoveryMutationReadbackValidationNoOpAndUndo() async throws {
        var timeline = Timeline()
        timeline.settingsConfigured = true
        let harness = ToolHarness(timeline: timeline)
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "custom-aspect-ratio-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)

            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "set_project_settings" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            let aspectRatioSchema = try #require(properties["aspectRatio"]?.objectValue)
            #expect(aspectRatioSchema["type"]?.stringValue == "string")
            #expect(aspectRatioSchema["enum"] == nil)

            let changed = try await client.callTool(name: "set_project_settings", arguments: [
                "aspectRatio": .string("2.39:1"),
                "quality": .string("4K"),
            ])
            #expect(changed.isError != true)
            let changedReceipt = try json(changed.content)
            #expect(changedReceipt["resolution"] as? String == "5162x2160")
            #expect(changedReceipt["changed"] as? [String] == ["resolution"])
            try await expectTimelineSize(width: 5162, height: 2160, client: client)

            let invalid = try await client.callTool(name: "set_project_settings", arguments: [
                "width": .int(1440),
            ])
            #expect(invalid.isError == true)
            try await expectTimelineSize(width: 5162, height: 2160, client: client)

            let repeated = try await client.callTool(name: "set_project_settings", arguments: [
                "aspectRatio": .string("2.39:1"),
                "quality": .string("4K"),
            ])
            #expect(repeated.isError != true)
            let repeatedReceipt = try json(repeated.content)
            #expect(repeatedReceipt["changed"] as? [String] == [])

            #expect((try await client.callTool(name: "undo")).isError != true)
            try await expectTimelineSize(width: 1920, height: 1080, client: client)
            #expect((try await client.callTool(name: "undo")).isError == true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func expectTimelineSize(width: Int, height: Int, client: Client) async throws {
        let result = try await client.callTool(name: "get_timeline")
        let timeline = try json(result.content)
        #expect(timeline["width"] as? Int == width)
        #expect(timeline["height"] as? Int == height)
    }

    private func json(_ content: [Tool.Content]) throws -> [String: Any] {
        guard case .text(let text, _, _) = content.first else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
