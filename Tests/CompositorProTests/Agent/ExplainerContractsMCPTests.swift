import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Explainer tool contracts")
@MainActor
struct ExplainerContractsMCPTests {
    @Test func discoveryDescribesAssemblyImportAndRequestedRuntime() async throws {
        try await withClient { client, _ in
            let (tools, _) = try await client.listTools()
            let apply = try #require(tools.first { $0.name == "apply_plan" })
            #expect(apply.description?.contains("assembles") == true)
            #expect(apply.description?.contains("no timeline edits") == false)
            let commit = try #require(apply.inputSchema.objectValue?["properties"]?.objectValue?["commit"]?.objectValue?["description"]?.stringValue)
            #expect(commit.contains("assemble"))
            let importer = try #require(tools.first { $0.name == "import_media" })
            #expect(importer.description?.contains("Lottie") == true)
            #expect(importer.description?.contains("5 GiB") == true)
            let mime = try #require(importer.inputSchema.objectValue?["properties"]?.objectValue?["source"]?.objectValue?["properties"]?.objectValue?["mimeType"]?.objectValue?["description"]?.stringValue)
            #expect(mime.contains("application/vnd.lottie+json"))
            #expect(mime.contains("audio/aiff"))
            #expect(AgentInstructions.serverInstructions.contains("Honor the requested duration and format"))
        }
    }

    @Test func approvedPlanAssemblesOnceAndUndoesThroughMCP() async throws {
        try await withClient { client, harness in
            let asset = harness.addAsset(id: "contract-asset", duration: 8)
            let baseline = harness.editor.timeline
            let created = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("create"),
                "plan": .object([
                    "planId": .string("contract-plan"), "name": .string("Coverage"),
                    "shots": .array([.object([
                        "shotId": .string("contract-shot"), "title": .string("Harbor"),
                        "startFrame": .int(0), "endFrame": .int(120),
                        "mediaRef": .string(asset.id),
                    ])]),
                ]),
            ])
            #expect(created.isError != true)
            let approved = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("status"), "planId": .string("contract-plan"), "status": .string("approved"),
            ])
            #expect(approved.isError != true)
            let undo = UndoManager()
            harness.editor.undo.attach(undo)

            let preview = try await client.callTool(name: "apply_plan", arguments: ["planId": .string("contract-plan")])
            #expect(try json(preview.content)["ready"] as? Bool == true)
            #expect(harness.editor.timeline == baseline)
            #expect(!undo.canUndo)

            let arguments: [String: Value] = ["planId": .string("contract-plan"), "commit": .bool(true)]
            let applied = try await client.callTool(name: "apply_plan", arguments: arguments)
            #expect(applied.isError != true)
            #expect(try json(applied.content)["applied"] as? Bool == true)
            let clips = harness.editor.timeline.tracks.flatMap(\.clips)
            #expect(clips.filter { $0.mediaRef == asset.id }.count == 1)
            let assembled = harness.editor.timeline
            let repeated = try await client.callTool(name: "apply_plan", arguments: arguments)
            #expect(try json(repeated.content)["noOp"] as? Bool == true)
            #expect(harness.editor.timeline == assembled)

            let read = try await client.callTool(name: "plan_edit", arguments: [
                "action": .string("read"), "planId": .string("contract-plan"),
            ])
            #expect(try json(read.content)["status"] as? String == "applied")
            let timeline = try await client.callTool(name: "get_timeline")
            #expect(try text(timeline.content).contains(try #require(clips.first?.id).prefix(8)))
            let undone = try await client.callTool(name: "undo")
            #expect(undone.isError != true)
            #expect(harness.editor.timeline == baseline)
            #expect(harness.editor.editPlan(id: "contract-plan")?.status == .approved)
            #expect(!undo.canUndo)
        }
    }

    @Test func invalidPlanAndUnsupportedMIMELeaveStateUnchangedThroughMCP() async throws {
        try await withClient { client, harness in
            let undo = UndoManager()
            harness.editor.undo.attach(undo)
            let baseline = harness.editor.timeline
            let invalid = try await client.callTool(name: "apply_plan", arguments: [
                "planId": .string("missing"), "commit": .bool(true),
            ])
            #expect(invalid.isError == true)
            harness.editor.projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).palmier")
            let unsupported = try await client.callTool(name: "import_media", arguments: [
                "source": .object(["bytes": .string("e30="), "mimeType": .string("application/unknown")]),
            ])
            #expect(unsupported.isError == true)
            #expect(try text(unsupported.content).contains("application/vnd.lottie+json"))
            #expect(harness.editor.timeline == baseline)
            #expect(harness.editor.mediaAssets.isEmpty)
            #expect(!undo.canUndo)
        }
    }

    private func withClient(_ operation: @MainActor (Client, ToolHarness) async throws -> Void) async throws {
        let harness = ToolHarness()
        let server = Server(name: "explainer-contracts", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "explainer-contract-tests", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await operation(client, harness)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func text(_ blocks: [Tool.Content]) throws -> String {
        for block in blocks { if case .text(let text, _, _) = block { return text } }
        throw CocoaError(.coderReadCorrupt)
    }

    private func json(_ blocks: [Tool.Content]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text(blocks).utf8)) as? [String: Any])
    }
}
