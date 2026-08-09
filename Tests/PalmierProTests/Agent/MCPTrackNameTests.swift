import Foundation
import MCP
import Testing
@testable import PalmierPro
@Suite("MCP track names")
@MainActor
struct MCPTrackNameTests {
    @Test func discoveryNamingReadbackAndUndoRoundTrip() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack()]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(name: "palmier-pro-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "track-name-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "manage_tracks" })
            let setSchema = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue?["set"]?.objectValue)
            let nameSchema = try #require(setSchema["items"]?.objectValue?["properties"]?.objectValue?["name"]?.objectValue)
            #expect(nameSchema["type"]?.stringValue == "string")
            #expect(nameSchema["maxLength"]?.intValue == TrackName.maximumLength)
            #expect(nameSchema["description"]?.stringValue?.contains("exactly one short word") == true)
            let initial = try await timeline(client)
            let trackId = try #require((initial["tracks"] as? [[String: Any]])?.first?["trackId"] as? String)
            let rename = try await setName("Dialogue", trackId: trackId, client: client)
            let receipt = try json(rename)
            #expect(((receipt["renamed"] as? [[String: Any]])?.first?["changed"] as? Bool) == true)
            let renamed = try await timeline(client)
            let renamedTrack = try #require((renamed["tracks"] as? [[String: Any]])?.first)
            #expect(renamedTrack["label"] as? String == "A1")
            #expect(renamedTrack["name"] as? String == "Dialogue")
            let noOp = try await setName("Dialogue", trackId: trackId, client: client)
            #expect(((try json(noOp)["renamed"] as? [[String: Any]])?.first?["changed"] as? Bool) == false)
            #expect((try await setName("Line one\nLine two", trackId: trackId, client: client)).isError == true)
            let clear = try await setName("", trackId: trackId, client: client)
            #expect(((try json(clear)["renamed"] as? [[String: Any]])?.first?["changed"] as? Bool) == true)
            let cleared = try await timeline(client)
            #expect((cleared["tracks"] as? [[String: Any]])?.first?["name"] == nil)
            #expect((try await client.callTool(name: "undo")).isError != true)
            let restoredName = try await timeline(client)
            #expect((restoredName["tracks"] as? [[String: Any]])?.first?["name"] as? String == "Dialogue")
            #expect((try await client.callTool(name: "undo")).isError != true)
            let restored = try await timeline(client)
            #expect((restored["tracks"] as? [[String: Any]])?.first?["name"] == nil)
            #expect((try await client.callTool(name: "undo")).isError == true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
    private func setName(_ name: String, trackId: String, client: Client) async throws
        -> (content: [Tool.Content], isError: Bool?) {
        try await client.callTool(name: "manage_tracks", arguments: [
            "set": .array([.object(["trackId": .string(trackId), "name": .string(name)])]),
        ])
    }
    private func timeline(_ client: Client) async throws -> [String: Any] { try json(try await client.callTool(name: "get_timeline")) }
    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        guard case .text(let text, _, _) = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
