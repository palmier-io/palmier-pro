import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Timeline clip identity")
@MainActor
struct ClipIdentityMCPTests {
    @Test(arguments: [30, 90])
    func repeatedMoveIDsLeaveDomainStateAndUndoUnchanged(secondFrame: Int) {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        harness.editor.moveClips([
            (clipId, 0, 30), (clipId, 0, secondFrame),
        ])
        #expect(harness.editor.timeline == before)
        #expect(!undo.canUndo)
    }

    @Test func repeatedFullAndShortMoveIDsAreRefusedThroughMCP() async throws {
        let harness = makeHarness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        let server = Server(name: "clip-identity", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "clip-identity-tests", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let refused = try await client.callTool(name: "move_clips", arguments: ["moves": .array([
                .object(["clipId": .string(clipId), "toFrame": .int(30)]),
                .object(["clipId": .string(String(clipId.prefix(8))), "toFrame": .int(90)]),
            ])])
            #expect(refused.isError == true)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
            let read = try await client.callTool(name: "get_timeline")
            let content = try #require(read.content.first)
            guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
            let timeline = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let tracks = try #require(timeline["tracks"] as? [[String: Any]])
            let clips = tracks.flatMap { $0["clips"] as? [[String: Any]] ?? [] }
            #expect(clips.count == 1)
            #expect(clips.first?["frames"] as? [Int] == [0, 30])

            let moved = try await client.callTool(name: "move_clips", arguments: ["moves": .array([
                .object(["clipId": .string(String(clipId.prefix(8))), "toFrame": .int(30)]),
            ])])
            #expect(moved.isError != true)
            #expect(harness.editor.timeline.tracks.flatMap(\.clips).map(\.id) == [clipId])
            #expect(harness.editor.timeline.tracks[0].clips[0].startFrame == 30)
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    @Test func repeatedPlacementCreatesDistinctClipIDsWithOneMediaReference() {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack()]))
        let asset = harness.addAsset(id: "one-input", type: .image)
        let first = harness.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 30)
        let second = harness.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 60, durationFrames: 30)
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first != second)
        #expect(Set(harness.editor.timeline.tracks.flatMap(\.clips).map(\.id)).count == 2)
        #expect(Set(harness.editor.timeline.tracks.flatMap(\.clips).map(\.mediaRef)) == [asset.id])
    }

    private var clipId: String { "ABCD1234-0000-0000-0000-000000000000" }

    private func makeHarness() -> ToolHarness {
        ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: clipId, start: 0, duration: 30)]),
        ]))
    }
}
