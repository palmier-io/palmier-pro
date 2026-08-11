import MCP
import Testing
@testable import PalmierPro

@Suite("MCP text animations")
@MainActor
struct MCPTextAnimationTests {
    @Test func discoveryAndValidationExcludeRemovedPresets() async throws {
        var clip = Fixtures.clip(
            id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60
        )
        clip.textContent = "Title"
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))
        let server = Server(
            name: "text-animation-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "text-animation-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let updateText = try #require(tools.first { $0.name == "update_text" })
            let properties = try #require(updateText.inputSchema.objectValue?["properties"]?.objectValue)
            let presets = try #require(properties["animation"]?.objectValue?["enum"]?.arrayValue)

            for preset in ["fadeIn", "wordPop", "wordCycle"] {
                #expect(!presets.contains(.string(preset)))
                let result = try await client.callTool(name: "update_text", arguments: [
                    "clipIds": .array([.string(clip.id)]),
                    "animation": .string(preset),
                ])
                #expect(result.isError == true)
                #expect(harness.editor.clipFor(id: clip.id)?.textAnimation == nil)
            }
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
