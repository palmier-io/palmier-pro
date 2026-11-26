import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("MCP single-word caption template")
@MainActor
struct CaptionSingleWordMCPTests {
    @Test func appliesSingleWordWithoutChangingCaptionContentOrTimingAndHasOneUndo() async throws {
        var first = Fixtures.clip(id: "A1111111-0000-0000-0000-000000000000", mediaType: .text, start: 41, duration: 90)
        first.captionGroupId = "single-word-captions"
        first.textContent = "New York!"
        first.textStyle = TextStyle()
        first.wordTimings = [.init(text: "New York", startFrame: 10, endFrame: 50)]
        var second = first
        second.id = "B2222222-0000-0000-0000-000000000000"
        second.startFrame = 150
        second.textContent = "Next phrase"
        second.wordTimings = [
            .init(text: "Next", startFrame: 0, endFrame: 30),
            .init(text: "phrase", startFrame: 40, endFrame: 70),
        ]
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [first, second])]))
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let request: [String: Value] = ["action": .string("apply"), "templateId": .string("one-word")]

        try await withClient(harness) { client in
            let (tools, _) = try await client.listTools()
            let update = try #require(tools.first { $0.name == "update_text" })
            let animation = try #require(update.inputSchema.objectValue?["properties"]?.objectValue?["animation"]?.objectValue)
            #expect(animation["type"] == .string("string"))
            #expect(animation["enum"]?.arrayValue?.contains(.string("singleWord")) == true)
            let template = try await object(client, tool: "caption_templates", arguments: [
                "action": .string("get"), "templateId": .string("one-word"),
            ])
            #expect(template["animationPreset"] as? String == "singleWord")
            let beforeRead = try await object(client, tool: "get_timeline", arguments: ["captionDetail": .bool(true)])

            let refused = try await client.callTool(name: "caption_templates", arguments: [
                "action": .string("apply"), "templateId": .string("missing"),
            ])
            #expect(refused.isError == true)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)

            let receipt = try await object(client, tool: "caption_templates", arguments: request)
            #expect(receipt["templateId"] as? String == "one-word")
            #expect(receipt["appliedClipCount"] as? Int == 2)
            let updatedIDs = try #require(receipt["updatedClipIds"] as? [String])
            #expect(Set(updatedIDs) == Set([String(first.id.prefix(8)), String(second.id.prefix(8))]))

            let after = harness.editor.timeline
            for (original, applied) in zip(before.tracks[0].clips, after.tracks[0].clips) {
                #expect(applied.id == original.id)
                #expect(applied.textContent == original.textContent)
                #expect(applied.wordTimings == original.wordTimings)
                #expect(applied.startFrame == original.startFrame)
                #expect(applied.durationFrames == original.durationFrames)
                #expect(applied.transform.width == original.transform.width)
                #expect(applied.transform.height == original.transform.height)
                #expect(applied.textAnimation?.preset == .singleWord)
            }
            let afterRead = try await object(client, tool: "get_timeline", arguments: ["captionDetail": .bool(true)])
            let beforeGroup = try captionGroup(beforeRead)
            let afterGroup = try captionGroup(afterRead)
            let beforeRows = try #require(beforeGroup["clips"] as? [[Any]])
            let afterRows = try #require(afterGroup["clips"] as? [[Any]])
            #expect(NSArray(array: afterRows).isEqual(to: beforeRows))
            #expect(afterGroup["frameRange"] as? [Int] == [41, 240])
            let shared = try #require(afterGroup["shared"] as? [String: Any])
            let appliedAnimation = try #require(shared["textAnimation"] as? [String: Any])
            #expect(appliedAnimation["preset"] as? String == "singleWord")

            _ = try await object(client, tool: "caption_templates", arguments: request)
            #expect(harness.editor.timeline == after)
            let undone = try await client.callTool(name: "undo")
            try #require(undone.isError != true)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
            undo.redo()
            #expect(harness.editor.timeline == after)
        }
    }

    private func captionGroup(_ timeline: [String: Any]) throws -> [String: Any] {
        let tracks = try #require(timeline["tracks"] as? [[String: Any]])
        let groups = try #require(tracks.first?["captionGroups"] as? [[String: Any]])
        return try #require(groups.first)
    }

    private func object(_ client: Client, tool: String, arguments: [String: Value]) async throws -> [String: Any] {
        let result = try await client.callTool(name: tool, arguments: arguments)
        try #require(result.isError != true)
        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func withClient(_ harness: ToolHarness, _ operation: (Client) async throws -> Void) async throws {
        let server = Server(name: "single-word-caption", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "single-word-caption-tests", version: "1")
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
