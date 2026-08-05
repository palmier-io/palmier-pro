import Foundation
import MCP
import Testing

@testable import PalmierPro

@Suite("MCP clip media swap")
@MainActor
struct SwapClipMediaToolTests {
    @Test func validatesSwapsReadsBackAndUndoes() async throws {
        let (oldMedia, newMedia) = ("old-media", "new-media")

        var video = Fixtures.clip(id: "video-clip", mediaRef: oldMedia, start: 12, duration: 30,
                                  trimStart: 10, trimEnd: 20, speed: 1.5, volume: 0.7)
        video.linkGroupId = "linked"
        video.transform = Transform(centerX: 0.4, centerY: 0.6, width: 0.7, height: 0.8, rotation: 15)
        video.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 5, value: 0.8)])
        video.effects = [Effect(type: "blur")]
        var audio = Fixtures.clip(id: "audio-clip", mediaRef: oldMedia, mediaType: .audio, start: 12,
                                  duration: 30, trimStart: 10, trimEnd: 20, speed: 1.5, volume: 0.25)
        audio.sourceClipType = .video
        audio.linkGroupId = "linked"

        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]), Fixtures.audioTrack(clips: [audio]),
        ]))
        harness.addAsset(id: newMedia, duration: 4, hasAudio: true)
        harness.addAsset(id: "short-media", duration: 1, hasAudio: true)
        harness.addAsset(id: "silent-media", duration: 4)
        harness.addAsset(id: "image-media", type: .image)
        let undoManager = UndoManager()
        harness.editor.undo.attach(undoManager)

        let server = Server(
            name: "palmier-pro-test", version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "clip-media-swap-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "swap_clip_media" })
            #expect(try #require(tool.inputSchema.objectValue?["required"]?.arrayValue)
                .compactMap(\.stringValue) == ["clipId", "mediaRef"])

            for mediaRef in ["short-media", "silent-media", "image-media"] {
                #expect((try await callSwap(client, clipId: video.id, mediaRef: mediaRef)).isError == true)
            }
            #expect(harness.editor.clipFor(id: video.id) == video)
            #expect(harness.editor.clipFor(id: audio.id) == audio)
            #expect(!undoManager.canUndo)

            let swap = try await callSwap(client, clipId: video.id, mediaRef: newMedia)
            let receipt = try json(swap)
            #expect(receipt["changed"] as? Bool == true)
            #expect(Set(receipt["affectedClipIds"] as? [String] ?? []) == Set([video.id, audio.id]))

            var expectedVideo = video
            expectedVideo.mediaRef = newMedia
            expectedVideo.trimEndFrame = 65
            var expectedAudio = audio
            expectedAudio.mediaRef = newMedia
            expectedAudio.trimEndFrame = 65
            #expect(harness.editor.clipFor(id: video.id) == expectedVideo)
            #expect(harness.editor.clipFor(id: audio.id) == expectedAudio)
            #expect(try await timelineMediaRef(client: client, clipId: video.id) == newMedia)

            let noOp = try await callSwap(client, clipId: video.id, mediaRef: newMedia)
            #expect(try json(noOp)["changed"] as? Bool == false)

            #expect((try await client.callTool(name: "undo")).isError != true)
            #expect(harness.editor.clipFor(id: video.id) == video)
            #expect(harness.editor.clipFor(id: audio.id) == audio)
            undoManager.redo()
            #expect(harness.editor.clipFor(id: video.id) == expectedVideo)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func timelineMutationCancelsPendingSwap() {
        let clip = Fixtures.clip(id: "clip", start: 0, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])]))

        harness.editor.beginMediaSwap(clipId: clip.id)
        harness.editor.timeline.tracks[0].clips[0].linkGroupId = "changed"

        #expect(harness.editor.pendingSwapClipId == nil)
        #expect(harness.editor.pendingSwapTargetClipIds.isEmpty)
    }

    private func callSwap(_ client: Client, clipId: String, mediaRef: String) async throws
        -> (content: [Tool.Content], isError: Bool?) {
        try await client.callTool(name: "swap_clip_media", arguments: [
            "clipId": .string(clipId),
            "mediaRef": .string(mediaRef),
        ])
    }

    private func timelineMediaRef(client: Client, clipId: String) async throws -> String {
        let payload = try json(try await client.callTool(name: "get_timeline"))
        let tracks = try #require(payload["tracks"] as? [[String: Any]])
        let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
        return try #require(clips.first { $0["id"] as? String == clipId }?["mediaRef"] as? String)
    }

    private func json(_ result: (content: [Tool.Content], isError: Bool?)) throws -> [String: Any] {
        guard case .text(let text, _, _) = result.content.first else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
