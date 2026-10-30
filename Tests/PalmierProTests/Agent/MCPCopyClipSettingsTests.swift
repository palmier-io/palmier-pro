import Foundation
import MCP
import Testing
@testable import PalmierPro

@Suite("MCP copy clip settings", .serialized)
@MainActor
struct MCPCopyClipSettingsTests {
    @Test func discoveryCopyReadbackNoOpValidationAndUndo() async throws {
        var source = Fixtures.clip(id: "source-video", mediaRef: "source-media", start: 0, duration: 60)
        source.opacity = 0.45
        source.transform = Transform(centerX: 0.25, centerY: 0.75, width: 0.4, height: 0.6, rotation: 15)
        source.crop = Crop(left: 0.1, top: 0.2, right: 0, bottom: 0)
        source.edgeRounding = 0.3
        source.blendMode = .screen
        source.effects = [.make("stylize.invert")]

        var target = Fixtures.clip(id: "target-video", mediaRef: "target-media", start: 90, duration: 45, speed: 1.25)
        target.fadeInFrames = 6
        target.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 10, value: 0.7)])
        let originalTarget = target
        let audio = Fixtures.clip(id: "target-audio", mediaType: .audio, start: 90, duration: 45)
        let image = Fixtures.clip(id: "target-image", mediaType: .image, start: 135, duration: 25)

        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(id: "video-track", clips: [source, target, image]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
        let undo = UndoManager()
        harness.editor.undo.attach(undo)

        let server = Server(
            name: "palmier-pro-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "copy-clip-settings-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "copy_clip_settings" })
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            #expect(properties["sourceClipId"]?.objectValue?["type"]?.stringValue == "string")
            #expect(properties["targetClipIds"]?.objectValue?["type"]?.stringValue == "array")
            #expect(properties["targetTrack"]?.objectValue?["type"]?.stringValue == "object")

            let arguments: [String: Value] = [
                "sourceClipId": .string(source.id),
                "targetTrack": .object([
                    "trackId": .string("video-track"),
                    "range": .array([.int(0), .int(160)]),
                ]),
            ]
            let result = try await client.callTool(name: "copy_clip_settings", arguments: arguments)
            #expect(result.isError != true)
            let receipt = try json(text(result.content))
            #expect(receipt["changed"] as? Bool == true)
            #expect(receipt["matchedClipCount"] as? Int == 1)
            #expect(receipt["changedClipCount"] as? Int == 1)
            #expect(receipt["unchangedClipCount"] as? Int == 0)
            #expect(receipt["incompatibleClipCount"] as? Int == 1)
            #expect(receipt["sourceExcluded"] as? Bool == true)
            #expect(receipt["targetClipIds"] == nil)
            #expect(receipt["changedClipIds"] == nil)
            #expect(receipt["excludedClipIds"] == nil)
            #expect(receipt["clips"] == nil)

            let repeated = try await client.callTool(name: "copy_clip_settings", arguments: arguments)
            #expect(repeated.isError != true)
            let repeatedReceipt = try json(text(repeated.content))
            #expect(repeatedReceipt["changed"] as? Bool == false)
            #expect(repeatedReceipt["changedClipCount"] as? Int == 0)
            #expect(repeatedReceipt["unchangedClipCount"] as? Int == 1)
            #expect(repeatedReceipt["unchangedClipIds"] == nil)

            let timelineResult = try await client.callTool(name: "get_timeline")
            let timeline = try json(text(timelineResult.content))
            let readTarget = try #require(((timeline["tracks"] as? [[String: Any]]) ?? [])
                .flatMap { ($0["clips"] as? [[String: Any]]) ?? [] }
                .first { ($0["id"] as? String).map { target.id.hasPrefix($0) } == true })
            #expect((readTarget["opacity"] as? NSNumber)?.doubleValue == source.opacity)
            #expect(readTarget["blendMode"] as? String == source.blendMode?.rawValue)
            #expect((readTarget["transform"] as? [String: Any])?["centerX"] as? Double == source.transform.centerX)
            #expect((readTarget["keyframes"] as? [String: Any])?["opacity"] != nil)
            #expect(readTarget["fadeInFrames"] as? Int == originalTarget.fadeInFrames)
            #expect((readTarget["speed"] as? NSNumber)?.doubleValue == originalTarget.speed)
            #expect((readTarget["effects"] as? [[String: Any]])?.first?["type"] as? String == "stylize.invert")

            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.clipFor(id: target.id) == originalTarget)
            #expect((try await client.callTool(name: "undo")).isError == true)

            let invalid = try await client.callTool(name: "copy_clip_settings", arguments: [
                "sourceClipId": .string(source.id),
                "targetClipIds": .array([.string(target.id), .string(audio.id)]),
            ])
            #expect(invalid.isError == true)
            #expect(harness.editor.clipFor(id: target.id) == originalTarget)
            #expect((try await client.callTool(name: "undo")).isError == true)

            let emptyRange = try await client.callTool(name: "copy_clip_settings", arguments: [
                "sourceClipId": .string(source.id),
                "targetTrack": .object([
                    "trackId": .string("video-track"),
                    "range": .array([.int(135), .int(160)]),
                ]),
            ])
            #expect(emptyRange.isError == true)
            #expect((try await client.callTool(name: "undo")).isError == true)
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

    private func text(_ content: [Tool.Content]) throws -> String {
        for item in content {
            if case .text(let text, _, _) = item { return text }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
