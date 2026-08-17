import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP timeline markers")
@MainActor
struct MCPMarkerTests {
    @Test func discoversCreatesReadsUpdatesAndUndoesMarker() async throws {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: 100)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip])
        ]))
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let server = Server(
            name: "marker-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "marker-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "manage_markers" })
            let create = try json(try await client.callTool(name: "manage_markers", arguments: [
                "action": .string("create"),
                "name": .string("Timeline note"),
                "startFrame": .int(20),
                "durationFrames": .int(10),
                "color": .string("#FF9500"),
                "comment": .string("Move subject left"),
            ]))
            let markerId = try #require((create["created"] as? [String: Any])?["markerId"] as? String)
            let timeline = try json(try await client.callTool(name: "get_timeline", arguments: [
                "startFrame": .int(15),
                "endFrame": .int(25),
            ]))
            let markers = try #require(timeline["markers"] as? [[String: Any]])
            let marker = try #require(markers.first)
            #expect(marker["name"] as? String == "Timeline note")
            #expect(marker["endFrame"] as? Int == 30)
            #expect(marker["color"] as? String == "#FF9500FF")
            #expect(marker["status"] as? String == "open")
            _ = try json(try await client.callTool(name: "manage_markers", arguments: [
                "action": .string("update"),
                "markerId": .string(markerId),
                "startFrame": .int(40),
                "color": .string("#34C759"),
                "comment": .string("Addressed"),
                "status": .string("review"),
            ]))
            #expect(harness.editor.timeline.markers.first?.startFrame == 40)
            #expect(harness.editor.timeline.markers.first?.comment == "Addressed")
            #expect(harness.editor.timeline.markers.first?.status == .review)
            #expect((try await client.callTool(name: "manage_markers", arguments: [
                "action": .string("update"),
                "markerId": .string(markerId),
                "status": .string("done"),
            ])).isError == true)
            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.timeline.markers.first?.startFrame == 20)
            #expect(harness.editor.timeline.markers.first?.status == .open)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        guard case .text(let text, _, _) = result.content.first else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
