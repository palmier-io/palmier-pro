import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP — text Gaussian blur", .serialized)
@MainActor
struct MCPTextGaussianBlurTests {
    @Test func discoveryMutationReadbackValidationNoOpAndUndo() async throws {
        var clip = Fixtures.clip(
            id: "text", mediaRef: "", mediaType: .text, start: 0, duration: 60
        )
        clip.textContent = "Soft focus"
        clip.textStyle = TextStyle()
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let server = Server(
            name: "text-gaussian-blur-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "text-gaussian-blur-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            for name in ["update_text", "add_captions"] {
                let tool = try #require(tools.first { $0.name == name })
                let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
                try expectBlurSchema(properties["style"])
            }
            let addTool = try #require(tools.first { $0.name == "add_texts" })
            let addProperties = try #require(addTool.inputSchema.objectValue?["properties"]?.objectValue)
            let entries = try #require(addProperties["entries"]?.objectValue?["items"]?.objectValue)
            try expectBlurSchema(entries["properties"]?.objectValue?["style"])

            let arguments: [String: Value] = [
                "clipIds": .array([.string(clip.id)]),
                "style": .object(["blur": .double(24)]),
            ]
            let genericEffect = try await client.callTool(name: "apply_effect", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "effects": .array([.object(["type": .string("blur.gaussian")])]),
            ])
            #expect(genericEffect.isError == true)

            let added = try await client.callTool(name: "add_texts", arguments: [
                "entries": .array([.object([
                    "startFrame": .int(60),
                    "endFrame": .int(120),
                    "content": .string("Blurred title"),
                    "style": .object(["blur": .double(12)]),
                ])]),
            ])
            #expect(added.isError != true)
            #expect(blur(in: try json(text(added.content))) == 12)
            #expect((try await client.callTool(name: "undo")).isError != true)

            let mutation = try await client.callTool(name: "update_text", arguments: arguments)
            let mutationPayload = try json(text(mutation.content))
            #expect(mutation.isError != true)
            #expect(mutationPayload["changed"] as? Bool == true)
            #expect(blur(in: mutationPayload) == 24)

            let timeline = try json(text(try await client.callTool(name: "get_timeline").content))
            #expect(blur(in: timeline) == 24)

            let noOp = try await client.callTool(name: "update_text", arguments: arguments)
            #expect(noOp.isError != true)
            #expect(try json(text(noOp.content))["changed"] as? Bool == false)

            let invalid = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(clip.id)]),
                "style": .object(["blur": .double(101)]),
            ])
            #expect(invalid.isError == true)
            let afterInvalid = try json(text(try await client.callTool(name: "get_timeline").content))
            #expect(blur(in: afterInvalid) == 24)

            #expect((try await client.callTool(name: "undo")).isError != true)
            let restored = try json(text(try await client.callTool(name: "get_timeline").content))
            #expect(blur(in: restored) == nil)
            #expect((try await client.callTool(name: "undo")).isError == true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func expectBlurSchema(_ rawStyle: Value?) throws {
        let style = try #require(rawStyle?.objectValue?["properties"]?.objectValue)
        #expect(style["blur"]?.objectValue?["minimum"]?.intValue == 0)
        #expect(style["blur"]?.objectValue?["maximum"]?.intValue == 100)
    }

    private func blur(in payload: [String: Any]) -> Double? {
        let clips: [[String: Any]]
        if let changed = payload["clips"] as? [[String: Any]] {
            clips = changed
        } else {
            let tracks = payload["tracks"] as? [[String: Any]]
            clips = tracks?.flatMap { $0["clips"] as? [[String: Any]] ?? [] } ?? []
        }
        return (clips.first?["textStyle"] as? [String: Any])?["blur"] as? Double
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
