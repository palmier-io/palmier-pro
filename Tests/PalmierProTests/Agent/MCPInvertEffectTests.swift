import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP — invert effect", .serialized)
@MainActor
struct MCPInvertEffectTests {
    @Test func discoveryMutationReadbackValidationAndUndo() async throws {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let server = Server(
            name: "invert-effect-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "invert-effect-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "apply_effect" })
            #expect(tool.description?.contains("stylize.invert — Invert: no params") == true)

            let mutation = try await client.callTool(name: "apply_effect", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "effects": .array([.object([
                    "type": .string("stylize.invert"),
                ])]),
            ])
            #expect(mutation.isError != true)
            let mutationEffect = invertEffect(in: try json(text(mutation.content)))
            #expect(mutationEffect != nil)
            #expect(mutationEffect?["params"] == nil)

            let timeline = try json(text(try await client.callTool(name: "get_timeline").content))
            #expect(invertEffect(in: timeline) != nil)

            let invalid = try await client.callTool(name: "apply_effect", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "effects": .array([.object([
                    "type": .string("stylize.invert"),
                    "params": .object(["amount": .double(1)]),
                ])]),
            ])
            #expect(invalid.isError == true)
            #expect(invertEffect(in: try json(text(try await client.callTool(name: "get_timeline").content))) != nil)

            let undo = try await client.callTool(name: "undo")
            #expect(undo.isError != true)
            let restored = try json(text(try await client.callTool(name: "get_timeline").content))
            #expect(invertEffect(in: restored) == nil)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func invertEffect(in payload: [String: Any]) -> [String: Any]? {
        let clips: [[String: Any]]
        if let changed = payload["clips"] as? [[String: Any]] {
            clips = changed
        } else {
            let tracks = payload["tracks"] as? [[String: Any]]
            clips = tracks?.flatMap { $0["clips"] as? [[String: Any]] ?? [] } ?? []
        }
        let effects = clips.first?["effects"] as? [[String: Any]]
        return effects?.first { $0["type"] as? String == "stylize.invert" }
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
