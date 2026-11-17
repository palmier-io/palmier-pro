import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("MCP distinct text replacements")
@MainActor
struct TextContentBatchMCPTests {
    private let firstID = "A1111111-0000-0000-0000-000000000000"
    private let secondID = "B2222222-0000-0000-0000-000000000000"

    @Test func serializedReplacementListCannotOverwriteSeveralCaptions() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        try await withClient(harness) { client in
            let result = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(firstID), .string(secondID)]),
                "content": .string("[\"First correction\", \"Second correction\"]"),
            ])
            #expect(result.isError == true)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func distinctReplacementsHaveIndependentReadbackAndOneUndo() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let entries: Value = .array([
            .object(["clipId": .string(String(firstID.prefix(8))), "content": .string("First correction")]),
            .object(["clipId": .string(secondID), "content": .string("Second correction")]),
        ])
        try await withClient(harness) { client in
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "update_text" })
            let schema = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue?["entries"]?.objectValue)
            #expect(schema["type"] == .string("array"))
            #expect(schema["items"]?.objectValue?["required"] == .array([.string("clipId"), .string("content")]))

            let updated = try await client.callTool(name: "update_text", arguments: ["entries": entries])
            try #require(updated.isError != true)
            #expect(try await captionTexts(client) == [String(firstID.prefix(8)): "First correction", String(secondID.prefix(8)): "Second correction"])
            for (old, new) in zip(before.tracks[0].clips, harness.editor.timeline.tracks[0].clips) {
                #expect(new.id == old.id)
                #expect(new.startFrame == old.startFrame && new.durationFrames == old.durationFrames)
                #expect(new.textStyle == old.textStyle)
                #expect(new.wordTimings == nil)
            }
            let after = harness.editor.timeline
            let repeated = try await client.callTool(name: "update_text", arguments: ["entries": entries])
            #expect(repeated.isError != true)
            #expect(harness.editor.timeline == after)

            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
            undo.redo()
            #expect(harness.editor.timeline == after)
        }
    }

    @Test func invalidBatchLeavesEveryCaptionAndUndoUnchanged() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let valid: Value = .object(["clipId": .string(firstID), "content": .string("Correction")])
        let invalid: [Value] = [
            .object(["clipId": .string("missing"), "content": .string("Other")]),
            .object(["clipId": .string(secondID), "content": .array([.string("Other")])]),
            .object(["clipId": .string(String(firstID.prefix(8))), "content": .string("Duplicate alias")]),
            .object(["clipId": .string(secondID), "content": .string("Other"), "unexpected": .bool(true)]),
        ]
        try await withClient(harness) { client in
            for entry in invalid {
                let result = try await client.callTool(name: "update_text", arguments: ["entries": .array([valid, entry])])
                #expect(result.isError == true)
                #expect(harness.editor.timeline == before)
                #expect(!undo.canUndo)
            }
            let mixedRequests: [[String: Value]] = [
                ["entries": .array([valid]), "clipIds": .array([.string(secondID)])],
                ["entries": .array([valid]), "captionGroupId": .string("captions")],
                ["entries": .array([valid]), "content": .string("Shared")],
            ]
            for mixed in mixedRequests {
                let result = try await client.callTool(name: "update_text", arguments: mixed)
                #expect(result.isError == true)
                #expect(harness.editor.timeline == before)
                #expect(!undo.canUndo)
            }
        }
    }

    @Test func singleAuthoredTextCanStillContainAJSONExample() async throws {
        let harness = makeHarness()
        harness.editor.timeline.tracks[0].clips[0].captionGroupId = nil
        let example = "[\"one\", \"two\"]"
        try await withClient(harness) { client in
            let result = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(firstID)]), "content": .string(example),
            ])
            #expect(result.isError != true)
            #expect(harness.editor.clipFor(id: firstID)?.textContent == example)
        }
    }

    private func makeHarness() -> ToolHarness {
        let clips = [firstID, secondID].enumerated().map { index, id in
            var clip = Fixtures.clip(id: id, mediaType: .text, start: index * 90, duration: 90)
            clip.captionGroupId = "captions"
            clip.textContent = "Original \(index)"
            clip.textStyle = TextStyle()
            clip.wordTimings = [.init(text: "Original", startFrame: 0, endFrame: 90)]
            return clip
        }
        return ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)]))
    }

    private func captionTexts(_ client: Client) async throws -> [String: String] {
        let result = try await client.callTool(name: "get_timeline", arguments: ["captionDetail": .bool(true)])
        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
        let timeline = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let tracks = try #require(timeline["tracks"] as? [[String: Any]])
        var texts: [String: String] = [:]
        for track in tracks {
            for group in track["captionGroups"] as? [[String: Any]] ?? [] {
                for row in group["clips"] as? [[Any]] ?? [] {
                    if row.count == 4, let id = row[0] as? String, let content = row[3] as? String {
                        texts[id] = content
                    }
                }
            }
        }
        return texts
    }

    private func withClient(_ harness: ToolHarness, _ operation: (Client) async throws -> Void) async throws {
        let server = Server(name: "text-batch", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "text-batch-tests", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            try await operation(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
