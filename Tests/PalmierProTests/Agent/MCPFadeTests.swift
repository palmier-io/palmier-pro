import Foundation
import MCP
import Testing

@testable import PalmierPro

@Suite("MCP clip fades")
@MainActor
struct MCPFadeTests {
    @Test func discoveryMutationReadbackValidationAndUndo() async throws {
        var clip = Fixtures.clip(id: "video", start: 0, duration: 60)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.25),
            Keyframe(frame: 30, value: 1),
        ])
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "clip-fades-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)

            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "set_clip_properties" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["fadeInFrames"]?.objectValue?["type"]?.stringValue == "integer")
            #expect(properties["fadeInFrames"]?.objectValue?["minimum"]?.intValue == 0)
            let curves = try #require(properties["fadeInInterpolation"]?.objectValue?["enum"]?.arrayValue)
            #expect(curves.compactMap(\.stringValue) == ["linear", "smooth"])

            let update = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "fadeInFrames": .int(12),
                "fadeOutFrames": .int(18),
                "fadeInInterpolation": .string("smooth"),
                "fadeOutInterpolation": .string("linear"),
            ])
            #expect(update.isError != true)

            let updated = try await timelineClip(client: client, clipId: clip.id)
            #expect(updated["fadeInFrames"] as? Int == 12)
            #expect(updated["fadeOutFrames"] as? Int == 18)
            #expect(updated["fadeInInterpolation"] as? String == "smooth")
            #expect((updated["keyframes"] as? [String: Any])?["opacity"] != nil)

            let invalid = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "fadeInFrames": .int(50),
                "fadeOutFrames": .int(20),
            ])
            #expect(invalid.isError == true)
            #expect(harness.editor.clipFor(id: clip.id)?.fadeInFrames == 12)
            #expect(harness.editor.clipFor(id: clip.id)?.fadeOutFrames == 18)

            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.clipFor(id: clip.id)?.fadeInFrames == 0)
            #expect(harness.editor.clipFor(id: clip.id)?.fadeOutFrames == 0)
            #expect(harness.editor.clipFor(id: clip.id)?.opacityTrack?.keyframes.count == 2)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func timelineClip(client: Client, clipId: String) async throws -> [String: Any] {
        let result = try await client.callTool(name: "get_timeline")
        let payload = try json(text(result.content))
        let tracks = try #require(payload["tracks"] as? [[String: Any]])
        let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
        return try #require(clips.first { $0["id"] as? String == clipId })
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
