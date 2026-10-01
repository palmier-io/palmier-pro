import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("find_shot_candidates tool")
@MainActor
struct FindShotCandidatesToolTests {
    @Test func discoveryAdvertisesTheRetrievalContract() async throws {
        let harness = ToolHarness()
        let server = Server(name: "shot-candidates-test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "shot-candidates-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "find_shot_candidates" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["query"] != nil)
            #expect(properties["kind"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue).sorted() == ["audio", "image", "video"])
            #expect(tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue).sorted() == ["kind", "query"])

            let invalid = try await client.callTool(name: "find_shot_candidates", arguments: [
                "query": .string("harbor"),
            ])
            #expect(invalid.isError == true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func invalidRequestsDoNotMutateCheckpointOrUndo() async throws {
        let harness = ToolHarness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        var checkpoints = 0
        harness.editor.onProjectCheckpointRequired = { checkpoints += 1 }

        let cases: [(String, [String: Any], String)] = [
            ("empty query", ["query": "   ", "kind": "video"], "query is empty"),
            ("unknown kind", ["query": "harbor", "kind": "film"], "kind must be one"),
            ("image cannot use spoken evidence", ["query": "harbor", "kind": "image", "scope": "spoken"], "Images have no spoken"),
            ("audio cannot use visual evidence", ["query": "waves", "kind": "audio", "scope": "visual"], "Audio has no visual"),
            ("both sources disabled", ["query": "harbor", "kind": "video", "includeLibrary": false, "includeRemote": false], "Set includeLibrary or includeRemote"),
            ("local-only option with remote option", ["query": "harbor", "kind": "video", "includeRemote": false, "maxDurationSeconds": 10], "only when includeRemote"),
            ("remote-only option with library option", ["query": "harbor", "kind": "video", "includeLibrary": false, "mediaRef": "asset-1"], "only when includeLibrary"),
            ("unknown key", ["query": "harbor", "kind": "video", "bogus": true], "unknown field"),
        ]
        for (index, (name, args, expected)) in cases.enumerated() {
            let result = await harness.runRaw("find_shot_candidates", args: args)
            let message = ToolHarness.textOf(result)
            #expect(result.isError, "case \(index) \(name): \(message)")
            #expect(message.contains(expected), "case \(index) \(name): \(message)")
        }
        #expect(!undoManager.canUndo)
        #expect(checkpoints == 0)
    }

    @Test func localOnlyReadsReturnExplicitEmptyResults() async throws {
        let harness = ToolHarness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        var checkpoints = 0
        harness.editor.onProjectCheckpointRequired = { checkpoints += 1 }

        let result = try await harness.runOK("find_shot_candidates", args: [
            "query": "harbor at dusk",
            "kind": "video",
            "scope": "spoken",
            "includeRemote": false,
        ]) as? [String: Any]
        #expect(result?["count"] as? Int == 0)
        #expect(result?["candidates"] as? [Any] != nil)
        #expect((result?["warnings"] as? [String] ?? []).contains("Remote stock search was disabled."))
        #expect(!undoManager.canUndo)
        #expect(checkpoints == 0)
    }
}
