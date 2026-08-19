import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP detect_scenes")
@MainActor
struct MCPDetectScenesTests {
    @Test func discoversDetectsAndReadsBackCuts() async throws {
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 30, 30), seconds: 2),
            .init(rgb: (30, 200, 30), seconds: 2),
            .init(rgb: (30, 30, 220), seconds: 2),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = ToolHarness()
        let asset = MediaAsset(id: "scene-src", url: url, type: .video, name: "Scenes", duration: 6)
        harness.editor.mediaAssets.append(asset)

        let server = Server(
            name: "scene-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "scene-test", version: "1.0.0")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "detect_scenes" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["mediaRef"]?.objectValue?["type"]?.stringValue == "string")
            #expect(properties["startSeconds"]?.objectValue?["type"]?.stringValue == "number")
            #expect(properties["endSeconds"]?.objectValue?["type"]?.stringValue == "number")

            let result = try json(try await client.callTool(name: "detect_scenes", arguments: [
                "mediaRef": .string(asset.id),
            ]))
            let cuts = try #require(result["cuts"] as? [NSNumber]).map(\.doubleValue)
            #expect(cuts.count == 2)
            #expect(abs(cuts[0] - 2) < 0.25)
            #expect(abs(cuts[1] - 4) < 0.25)
            let scenes = try #require(result["scenes"] as? [[String: Any]])
            #expect(scenes.count == 3)

            let stored = try #require(harness.editor.mediaVisualCache.scenes.analysis(for: asset.id))
            #expect(stored.cuts.count == 2)

            let windowed = try json(try await client.callTool(name: "detect_scenes", arguments: [
                "mediaRef": .string(asset.id),
                "startSeconds": .double(3),
                "endSeconds": .double(5),
            ]))
            let windowCuts = try #require(windowed["cuts"] as? [NSNumber]).map(\.doubleValue)
            #expect(windowCuts.count == 1)
            #expect(abs(windowCuts[0] - 4) < 0.25)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func rejectsAudioAndUnknownFields() async throws {
        let harness = ToolHarness()
        harness.addAsset(id: "audio-1", type: .audio, duration: 4)

        let audio = await harness.executor.execute(name: "detect_scenes", args: ["mediaRef": "audio-1"])
        #expect(audio.isError)
        #expect(ToolHarness.textOf(audio).contains("needs video"))

        let unknown = await harness.executor.execute(name: "detect_scenes", args: [
            "mediaRef": "audio-1",
            "threshold": 12,
        ])
        #expect(unknown.isError)
        #expect(ToolHarness.textOf(unknown).contains("unknown field"))
    }

    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        guard case .text(let text, _, _) = result.content.first else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
