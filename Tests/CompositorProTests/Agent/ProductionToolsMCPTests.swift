import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Production tools through MCP")
@MainActor
struct ProductionToolsMCPTests {
    @Test func discoveryExposesTheProductionContract() async throws {
        try await withClient { client, _ in
            let (tools, _) = try await client.listTools()
            let produce = try #require(tools.first { $0.name == "produce_plan" })
            #expect(produce.inputSchema.objectValue?["required"]?.arrayValue == [.string("planId")])
            let description = try #require(produce.description)
            #expect(description.contains("resumes where it stopped"))
            #expect(description.contains("reviewed revision"))
            let status = try #require(tools.first { $0.name == "production_status" })
            #expect(status.inputSchema.objectValue?["required"]?.arrayValue == [.string("planId")])
            #expect(try #require(status.description).contains("blocked dependency"))
        }
    }

    @Test func productionStatusReportsThePersistedRunWithoutMutating() async throws {
        try await withClient { client, harness in
            let plan = try PlanAssemblyFixtures.plan(in: harness.editor)
            let baseline = harness.editor.editPlans
            let result = try await call(client, "production_status", ["planId": .string(plan.id)])
            #expect(result["planId"] as? String == plan.id)
            #expect(result["phase"] as? String == "awaiting_storyboard_approval")
            #expect((result["steps"] as? [Any])?.isEmpty == true)
            #expect(harness.editor.editPlans == baseline)
        }
    }

    @Test func productionRefusesAnUnapprovedPlan() async throws {
        try await withClient { client, harness in
            let plan = try PlanAssemblyFixtures.plan(in: harness.editor)
            let result = try await client.callTool(name: "produce_plan", arguments: ["planId": .string(plan.id)])
            #expect(result.isError == true)
            let text = result.content.compactMap {
                if case .text(let value, _, _) = $0 { return value } else { return nil }
            }.joined(separator: " ")
            #expect(text.contains("storyboard"))
            #expect(harness.exportQueue.jobs.isEmpty)
        }
    }

    private func withClient(_ body: @MainActor (Client, ToolHarness) async throws -> Void) async throws {
        let harness = ToolHarness()
        let server = Server(name: "production-tools", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "production-tools-test", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await body(client, harness)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func call(_ client: Client, _ name: String, _ args: [String: Value]) async throws -> [String: Any] {
        let result = try await client.callTool(name: name, arguments: args)
        try #require(result.isError != true)
        for item in result.content {
            if case .text(let text, _, _) = item {
                return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }}
