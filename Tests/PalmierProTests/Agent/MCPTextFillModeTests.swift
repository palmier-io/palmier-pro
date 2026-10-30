import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP text fill modes")
@MainActor
struct MCPTextFillModeTests {
    @Test func discoveryAddUpdateReadbackValidationAndUndo() async throws {
        var original = Fixtures.clip(
            id: "title", mediaRef: "text", mediaType: .text, start: 0, duration: 60
        )
        original.textContent = "Original"
        original.textStyle = TextStyle()
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [original]),
        ]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)
        let server = Server(
            name: "text-fill-mode-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "text-fill-mode-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let expectedModes = ["color", "footage", "inverted"]
            let updateText = try #require(tools.first { $0.name == "update_text" })
            let updateProperties = try #require(
                updateText.inputSchema.objectValue?["properties"]?.objectValue
            )
            let updateModes = try #require(
                updateProperties["fillMode"]?.objectValue?["enum"]?.arrayValue
            )
            #expect(updateModes.compactMap(\.stringValue) == expectedModes)

            let addTexts = try #require(tools.first { $0.name == "add_texts" })
            let addProperties = try #require(
                addTexts.inputSchema.objectValue?["properties"]?.objectValue
            )
            let entryProperties = try #require(
                addProperties["entries"]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue
            )
            let addModes = try #require(
                entryProperties["fillMode"]?.objectValue?["enum"]?.arrayValue
            )
            #expect(addModes.compactMap(\.stringValue) == expectedModes)

            let add = try await client.callTool(name: "add_texts", arguments: [
                "entries": .array([.object([
                    "startFrame": .int(0),
                    "endFrame": .int(60),
                    "content": .string("Invert me"),
                    "fillMode": .string("inverted"),
                ])]),
            ])
            #expect(add.isError != true)
            let added = try #require(
                harness.editor.timeline.tracks.flatMap(\.clips).first {
                    $0.textContent == "Invert me"
                }
            )
            #expect(added.textFillMode == .inverted)
            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.clipFor(id: added.id) == nil)

            let addFootage = try await client.callTool(name: "add_texts", arguments: [
                "entries": .array([.object([
                    "startFrame": .int(0),
                    "endFrame": .int(60),
                    "content": .string("Stencil me"),
                    "fillMode": .string("footage"),
                ])]),
            ])
            #expect(addFootage.isError != true)
            let addedFootage = try #require(
                harness.editor.timeline.tracks.flatMap(\.clips).first {
                    $0.textContent == "Stencil me"
                }
            )
            #expect(addedFootage.textFillMode == .footage)
            #expect(addedFootage.textStyle?.color == TextFillMode.defaultFootageMatteColor)
            #expect((try await client.callTool(name: "undo")).isError != true)

            let addColoredFootage = try await client.callTool(name: "add_texts", arguments: [
                "entries": .array([.object([
                    "startFrame": .int(0),
                    "endFrame": .int(60),
                    "content": .string("Green stencil"),
                    "fillMode": .string("footage"),
                    "style": .object(["color": .string("#00FF00")]),
                ])]),
            ])
            #expect(addColoredFootage.isError != true)
            let addedColoredFootage = try #require(
                harness.editor.timeline.tracks.flatMap(\.clips).first {
                    $0.textContent == "Green stencil"
                }
            )
            #expect(addedColoredFootage.textFillMode == .footage)
            #expect(
                addedColoredFootage.textStyle?.color
                    == TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1)
            )
            #expect((try await client.callTool(name: "undo")).isError != true)

            let footageUpdate = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(original.id)]),
                "fillMode": .string("footage"),
            ])
            #expect(footageUpdate.isError != true)
            #expect(harness.editor.clipFor(id: original.id)?.textFillMode == .footage)
            #expect(
                harness.editor.clipFor(id: original.id)?.textStyle?.color
                    == TextFillMode.defaultFootageMatteColor
            )
            let footageReadback = try await timelineClip(client: client, clipId: original.id)
            #expect(footageReadback["textFillMode"] as? String == "footage")
            #expect((try await client.callTool(name: "undo")).isError != true)

            let update = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(original.id)]),
                "fillMode": .string("inverted"),
            ])
            #expect(update.isError != true)
            #expect(harness.editor.clipFor(id: original.id)?.textFillMode == .inverted)
            let readback = try await timelineClip(client: client, clipId: original.id)
            #expect(readback["textFillMode"] as? String == "inverted")

            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.clipFor(id: original.id)?.textFillMode == nil)

            let invalid = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(original.id)]),
                "fillMode": .string("difference"),
            ])
            #expect(invalid.isError == true)
            #expect(harness.editor.clipFor(id: original.id)?.textFillMode == nil)
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
