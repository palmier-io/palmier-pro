import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP static rotation", .serialized)
@MainActor
struct MCPStaticRotationTests {
    @Test func discoveryExposesRotationInTransformSchemas() async throws {
        let harness = ToolHarness()

        try await withClient(harness: harness, name: "rotation-discovery-test") { client in
            let (tools, _) = try await client.listTools()

            let clipTool = try #require(tools.first { $0.name == "set_clip_properties" })
            let clipProperties = try #require(clipTool.inputSchema.objectValue?["properties"]?.objectValue)
            let clipTransform = try #require(clipProperties["transform"]?.objectValue?["properties"]?.objectValue)
            #expect(clipTransform["rotation"]?.objectValue?["type"]?.stringValue == "number")

            let addTool = try #require(tools.first { $0.name == "add_texts" })
            let addProperties = try #require(addTool.inputSchema.objectValue?["properties"]?.objectValue)
            let entries = try #require(addProperties["entries"]?.objectValue)
            let entryProperties = try #require(entries["items"]?.objectValue?["properties"]?.objectValue)
            let addTransform = try #require(entryProperties["transform"]?.objectValue?["properties"]?.objectValue)
            #expect(addTransform["rotation"]?.objectValue?["type"]?.stringValue == "number")

            let updateTool = try #require(tools.first { $0.name == "update_text" })
            let updateProperties = try #require(updateTool.inputSchema.objectValue?["properties"]?.objectValue)
            let updateTransform = try #require(updateProperties["transform"]?.objectValue?["properties"]?.objectValue)
            #expect(updateTransform["rotation"]?.objectValue?["type"]?.stringValue == "number")
        }
    }

    @Test func textRotationCreatesUpdatesReadsBackAndUndoesThroughMCP() async throws {
        let harness = ToolHarness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        try await withClient(harness: harness, name: "text-rotation-test") { client in
            let addResult = try await client.callTool(name: "add_texts", arguments: [
                "entries": .array([.object([
                    "startFrame": .int(0),
                    "endFrame": .int(60),
                    "content": .string("Rotated title"),
                    "transform": .object(["rotation": .double(30)]),
                ])]),
            ])
            #expect(addResult.isError != true)
            let textClip = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.mediaType == .text })
            let clipId = textClip.id
            #expect(textClip.transform.rotation == 30)
            #expect(textClip.transform.width < 1)
            #expect(textClip.transform.height < 1)
            try await expectTimelineRotation(30, clipId: clipId, client: client)

            let keyframeResult = try await client.callTool(name: "set_keyframes", arguments: [
                "clipId": .string(clipId),
                "property": .string("rotation"),
                "keyframes": .array([
                    .array([.int(0), .double(15)]),
                    .array([.int(30), .double(45)]),
                ]),
            ])
            #expect(keyframeResult.isError != true)

            let updateResult = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(clipId)]),
                "transform": .object(["rotation": .double(90)]),
            ])
            #expect(updateResult.isError != true)
            let updateReceipt = try json(text(updateResult.content))
            let notes = updateReceipt["notes"] as? [String]
            #expect(notes?.contains { $0.contains("cleared existing rotation keyframes") } == true)
            let updated = try #require(harness.editor.clipFor(id: clipId))
            #expect(updated.transform.rotation == 90)
            #expect(updated.rotationTrack == nil)
            #expect(updated.transform.width == textClip.transform.width)
            #expect(updated.transform.height == textClip.transform.height)
            try await expectTimelineRotation(90, clipId: clipId, client: client)

            let repeatedResult = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(clipId)]),
                "transform": .object(["rotation": .double(90)]),
            ])
            #expect(repeatedResult.isError != true)
            let repeatedReceipt = try json(text(repeatedResult.content))
            #expect(repeatedReceipt["changed"] as? Bool == false)

            #expect((try await client.callTool(name: "undo")).isError != true)
            let restoredTrack = try #require(harness.editor.clipFor(id: clipId)?.rotationTrack)
            #expect(restoredTrack.keyframes.map(\.value) == [15, 45])
            #expect(harness.editor.clipFor(id: clipId)?.transform.rotation == 30)

            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.clipFor(id: clipId)?.rotationTrack == nil)
            #expect(harness.editor.clipFor(id: clipId)?.transform.rotation == 30)

            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.clipFor(id: clipId) == nil)
            #expect((try await client.callTool(name: "undo")).isError == true)
        }
    }

    @Test func rotationDoesNotDisableContentAutoFitThroughMCP() async throws {
        let harness = ToolHarness()
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        try await withClient(harness: harness, name: "rotation-auto-fit-test") { client in
            let addResult = try await client.callTool(name: "add_texts", arguments: [
                "entries": .array([.object([
                    "startFrame": .int(0),
                    "endFrame": .int(60),
                    "content": .string("I"),
                    "transform": .object(["rotation": .double(15)]),
                ])]),
            ])
            #expect(addResult.isError != true)
            let original = try #require(harness.editor.timeline.tracks.flatMap(\.clips).first { $0.mediaType == .text })

            let updateResult = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string(original.id)]),
                "content": .string("A much longer title"),
                "transform": .object(["rotation": .double(45)]),
            ])
            #expect(updateResult.isError != true)
            let updated = try #require(harness.editor.clipFor(id: original.id))
            #expect(updated.transform.rotation == 45)
            #expect(updated.transform.width > original.transform.width)

            #expect((try await client.callTool(name: "undo")).isError != true)
            let restored = try #require(harness.editor.clipFor(id: original.id))
            #expect(restored.textContent == "I")
            #expect(restored.transform == original.transform)
        }
    }

    @Test func genericRotationClearsKeyframesAndUndoRestoresThemThroughMCP() async throws {
        var clip = Fixtures.clip(id: "video", start: 0, duration: 60)
        clip.rotationTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0),
            Keyframe(frame: 30, value: 45),
        ])
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        try await withClient(harness: harness, name: "clip-rotation-test") { client in
            let result = try await client.callTool(name: "set_clip_properties", arguments: [
                "clipIds": .array([.string("video")]),
                "transform": .object(["rotation": .double(-90)]),
            ])
            #expect(result.isError != true)
            #expect(harness.editor.clipFor(id: "video")?.transform.rotation == -90)
            #expect(harness.editor.clipFor(id: "video")?.rotationTrack == nil)
            try await expectTimelineRotation(-90, clipId: "video", client: client)

            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.clipFor(id: "video")?.transform.rotation == 0)
            #expect(harness.editor.clipFor(id: "video")?.rotationTrack?.keyframes.map(\.value) == [0, 45])
        }
    }

    @Test func stringTextRotationIsRejectedWithoutMutationOrUndo() async throws {
        var clip = Fixtures.clip(id: "title", mediaRef: "", mediaType: .text, start: 0, duration: 60)
        clip.textContent = "Title"
        clip.transform.rotation = 12
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        try await withClient(harness: harness, name: "invalid-rotation-test") { client in
            let result = try await client.callTool(name: "update_text", arguments: [
                "clipIds": .array([.string("title")]),
                "transform": .object(["rotation": .string("90")]),
            ])

            #expect(result.isError == true)
            #expect(harness.editor.clipFor(id: "title")?.transform.rotation == 12)
            #expect((try await client.callTool(name: "undo")).isError == true)
        }
    }

    private func withClient(
        harness: ToolHarness,
        name: String,
        operation: (Client) async throws -> Void
    ) async throws {
        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: name, version: "1.0.0")

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

    private func expectTimelineRotation(_ expected: Double, clipId: String, client: Client) async throws {
        let timelineResult = try await client.callTool(name: "get_timeline")
        let timeline = try json(text(timelineResult.content))
        let clip = try #require(((timeline["tracks"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
            .first { ($0["id"] as? String).map { clipId.hasPrefix($0) || $0.hasPrefix(clipId) } == true })
        let transform = try #require(clip["transform"] as? [String: Any])
        #expect((transform["rotation"] as? NSNumber)?.doubleValue == expected)
        #expect((clip["keyframes"] as? [String: Any])?["rotation"] == nil)
    }

    private func json(_ value: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let value, _, _) = item { return value }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
