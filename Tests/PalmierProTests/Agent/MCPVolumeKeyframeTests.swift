import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP volume keyframes", .serialized)
@MainActor
struct MCPVolumeKeyframeTests {
    @Test func decibelVolumeRoundTripsAndUndoesThroughMCP() async throws {
        let harness = ToolHarness()
        _ = harness.editor.insertTrack(at: 0, type: .video)
        let asset = harness.addAsset(type: .video)
        let clipId = try #require(harness.editor.placeClip(
            asset: asset,
            trackIndex: 0,
            startFrame: 0,
            durationFrames: 60
        ).first)
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "volume-keyframes-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "set_keyframes" })
            #expect(tool.description?.contains("volumeDb `[frame, decibels]` — −60 through +15 dB") == true)
            let keyframeProperties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            let propertyValues = try #require(keyframeProperties["property"]?.objectValue?["enum"]?.arrayValue)
            #expect(propertyValues.contains(.string("volumeDb")))
            #expect(!propertyValues.contains(.string("volume")))

            let clipTool = try #require(tools.first { $0.name == "set_clip_properties" })
            let clipProperties = try #require(clipTool.inputSchema.objectValue?["properties"]?.objectValue)
            let volumeSchema = try #require(clipProperties["volumeDb"]?.objectValue)
            #expect(number(volumeSchema["minimum"]) == VolumeScale.floorDb)
            #expect(number(volumeSchema["maximum"]) == VolumeScale.ceilingDb)
            #expect(clipProperties["volume"] == nil)

            let setResult = try await client.callTool(name: "set_keyframes", arguments: [
                "clipId": .string(clipId),
                "property": .string("volumeDb"),
                "keyframes": .array([
                    .array([.int(0), .double(0)]),
                    .array([.int(30), .double(-6), .string("linear")]),
                    .array([.int(60), .double(-60)]),
                ]),
            ])
            #expect(setResult.isError != true)
            let receipt = try json(text(setResult.content))
            let receiptClip = try #require((receipt["clips"] as? [[String: Any]])?.first)
            #expect((receiptClip["keyframes"] as? [String: Any])?["volumeDb"] != nil)
            #expect((receiptClip["keyframes"] as? [String: Any])?["volume"] == nil)

            let location = try #require(harness.editor.findClip(id: clipId))
            let stored = try #require(
                harness.editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].volumeTrack
            ).keyframes
            #expect(stored.count == 3)
            #expect(abs(stored[0].value) < 0.0001)
            #expect(stored[1].value == -6)
            #expect(stored[2].value == VolumeScale.floorDb)

            let timelineResult = try await client.callTool(name: "get_timeline")
            let timeline = try json(text(timelineResult.content))
            let clip = try #require(((timeline["tracks"] as? [[String: Any]]) ?? [])
                .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
                .first { ($0["id"] as? String).map { clipId.hasPrefix($0) } == true })
            let rows = try #require((clip["keyframes"] as? [String: Any])?["volumeDb"] as? [[Any]])
            #expect(rows.count == 3)
            #expect(abs(((rows[0][1] as? NSNumber)?.doubleValue ?? -1) - 0) < 0.0001)
            #expect(abs(((rows[1][1] as? NSNumber)?.doubleValue ?? -1) - -6) < 0.0001)
            #expect(abs(((rows[2][1] as? NSNumber)?.doubleValue ?? -1) - -60) < 0.0001)
            #expect((clip["keyframes"] as? [String: Any])?["volume"] == nil)

            let undoResult = try await client.callTool(name: "undo")
            #expect(undoResult.isError != true)
            let restoredLocation = try #require(harness.editor.findClip(id: clipId))
            #expect(
                harness.editor.timeline.tracks[restoredLocation.trackIndex]
                    .clips[restoredLocation.clipIndex].volumeTrack == nil
            )
            let emptyUndoResult = try await client.callTool(name: "undo")
            #expect(emptyUndoResult.isError == true)

            let removedPropertyResult = try await client.callTool(name: "set_keyframes", arguments: [
                "clipId": .string(clipId),
                "property": .string("volume"),
                "keyframes": .array([.array([.int(0), .double(1)])]),
            ])
            #expect(removedPropertyResult.isError == true)

            let outOfRangeResult = try await client.callTool(name: "set_keyframes", arguments: [
                "clipId": .string(clipId),
                "property": .string("volumeDb"),
                "keyframes": .array([.array([.int(0), .double(15.01)])]),
            ])
            #expect(outOfRangeResult.isError == true)
            #expect(
                harness.editor.timeline.tracks[restoredLocation.trackIndex]
                    .clips[restoredLocation.clipIndex].volumeTrack == nil
            )
            let invalidUndoResult = try await client.callTool(name: "undo")
            #expect(invalidUndoResult.isError == true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func number(_ value: Value?) -> Double? {
        value?.doubleValue ?? value?.intValue.map(Double.init)
    }

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
