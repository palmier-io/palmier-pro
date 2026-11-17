import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Plugin tools through MCP", .serialized)
@MainActor
struct PluginMCPTests {
    private let fm = FileManager.default

    private func makeStore() -> PluginStore {
        PluginStore(rootDirectory: fm.temporaryDirectory.appendingPathComponent("plugin-mcp-\(UUID().uuidString)"))
    }

    private func withClient(_ executor: ToolExecutor, body: (Client) async throws -> Void) async throws {
        let server = Server(name: "plugins", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let pair = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "plugin-tests", version: "1")
        try await server.start(transport: pair.server)
        do {
            _ = try await client.connect(transport: pair.client)
            try await body(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func installedSamplePluginIsListedAndCallableEndToEnd() async throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.rootDirectory) }
        let registry = ToolRegistry(store: store)
        _ = await store.installBuiltInSampleIfNeeded()
        await registry.reload()

        let tool = try #require(registry.tool(named: "sample_echo"))
        #expect(tool.plugin.trust == .trusted)

        let executor = ToolExecutor(projectProvider: { nil })
        executor.pluginRegistry = registry

        try await withClient(executor) { (client: Client) async throws in
            let listed = try await client.listTools()
            #expect(listed.tools.contains { $0.name == "sample_echo" })
            #expect(listed.tools.contains { $0.name == ToolName.getTimeline.rawValue })

            let called = try await client.callTool(name: "sample_echo", arguments: ["message": .string("hello")])
            #expect(called.isError != true)
            let text = try #require(called.content.first)
            guard case .text(let json, _, _) = text else { throw CocoaError(.coderReadCorrupt) }
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(object["plugin"] as? String == "compositor.sample.echo")
            #expect((object["argumentsReceived"] as? Int ?? 0) > 0)
        }
    }

    @Test func untrustedPluginCallFailsThroughMCPWithARemedy() async throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.rootDirectory) }
        let registry = ToolRegistry(store: store)
        _ = await store.installBuiltInSampleIfNeeded()
        await registry.reload()
        let tool = try #require(registry.tool(named: "sample_echo"))
        registry.replace(with: [
            InstalledPlugin(manifest: tool.plugin.manifest, directory: tool.plugin.directory, trust: .untrusted, digest: tool.plugin.digest),
        ])

        let executor = ToolExecutor(projectProvider: { nil })
        executor.pluginRegistry = registry
        try await withClient(executor) { (client: Client) async throws in
            let called = try await client.callTool(name: "sample_echo", arguments: ["message": .string("hello")])
            #expect(called.isError == true)
        }
    }

    @Test func unknownToolStillFails() async throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.rootDirectory) }
        let registry = ToolRegistry(store: store)
        await registry.ensureLoaded()
        let executor = ToolExecutor(projectProvider: { nil })
        executor.pluginRegistry = registry

        try await withClient(executor) { (client: Client) async throws in
            let called = try await client.callTool(name: "not_a_plugin_tool", arguments: [:])
            #expect(called.isError == true)
        }
    }
}
