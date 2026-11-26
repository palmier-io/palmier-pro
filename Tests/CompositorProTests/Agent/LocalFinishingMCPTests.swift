import AVFoundation
import Foundation
import MCP
import Testing
@testable import CompositorPro

@MainActor
struct LocalFinishingMCPTests {
    @Test func finishesReviewsExportsAndUndoesThroughMCP() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let harness = ToolHarness()
        let asset = harness.makeAsset(name: "tone", type: .audio, duration: 3)
        asset.url = directory.appendingPathComponent("tone.wav")
        harness.editor.mediaManifest.entries[0].source = .external(absolutePath: asset.url.path)
        let audio = Fixtures.clip(mediaRef: asset.id, mediaType: .audio, start: 0, duration: 60)
        var title = Fixtures.clip(mediaRef: "", mediaType: .text, start: 0, duration: 60)
        title.textContent = "Local review"
        harness.editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [title]), Fixtures.audioTrack(clips: [audio])])
        harness.editor.timeline.width = 320
        harness.editor.timeline.height = 180
        let baseline = harness.editor.timeline
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let server = Server(name: "local-finishing", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "local-finishing-test", version: "1")
        try await server.start(transport: transports.server)
        var reviewURL: URL?
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            #expect(tools.contains { $0.name == "review_timeline" })
            let exports = try #require(tools.first { $0.name == "manage_exports" })
            #expect(exports.inputSchema.objectValue?["properties"]?.objectValue?["action"]?.objectValue?["enum"]?.arrayValue?.contains(.string("wait")) == true)

            let invalid = try await client.callTool(name: "review_timeline", arguments: ["startFrame": .double(0.5)])
            #expect(invalid.isError == true)
            #expect(harness.editor.timeline == baseline)
            #expect(!undo.canUndo)

            let invalidMatch = try await client.callTool(name: "match_loudness", arguments: [
                "clipIds": .array([.string(audio.id), .string("missing")]),
            ])
            #expect(invalidMatch.isError == true)
            #expect(harness.editor.timeline == baseline)
            #expect(!undo.canUndo)

            let matched = try await client.callTool(name: "match_loudness", arguments: ["clipIds": .array([.string(audio.id)])])
            #expect(matched.isError != true)
            #expect(try json(matched.content)["noOp"] as? Bool == false)
            #expect(harness.editor.clipFor(id: audio.id)?.loudnessGainDB ?? 0 > 0)
            let changed = harness.editor.timeline
            let repeated = try await client.callTool(name: "match_loudness", arguments: ["clipIds": .array([.string(audio.id)])])
            #expect(try json(repeated.content)["noOp"] as? Bool == true)
            #expect(harness.editor.timeline == changed)
            let readback = try await client.callTool(name: "get_timeline")
            #expect(try text(readback.content).contains(Clip.loudnessEffectType))

            let reviewed = try await client.callTool(name: "review_timeline")
            let reviewText = try text(reviewed.content)
            #expect(reviewed.isError != true, "\(reviewText)")
            let review = try json(reviewed.content)
            reviewURL = URL(fileURLWithPath: try #require(review["path"] as? String))
            #expect(review["hasAudio"] as? Bool == true)
            #expect(abs((review["integratedLUFS"] as? Double ?? 0) + 16) < 0.5)
            #expect(review["clippedSamples"] as? Int == 0)
            #expect((review["sampledFrames"] as? [Int])?.count == 6)

            let output = directory.appendingPathComponent("finished.mp4")
            let queued = try await client.callTool(name: "export_project", arguments: [
                "outputPath": .string(output.path), "codec": .string("h264"), "resolution": .string("Match Timeline"),
            ])
            let queuedText = try text(queued.content)
            #expect(queued.isError != true, "\(queuedText)")
            let jobID = try #require(try json(queued.content)["jobId"] as? String)
            let finished = try await client.callTool(name: "manage_exports", arguments: ["action": .string("wait"), "jobId": .string(jobID)])
            let finishedText = try text(finished.content)
            #expect(try json(finished.content)["status"] as? String == "completed", "\(finishedText)")
            let measured = try await LoudnessAnalyzer.integratedLoudness(for: output, mediaRef: "encoded",
                                                                        cacheDirectory: directory.appendingPathComponent("cache"))
            #expect(abs((measured.integratedLUFS ?? 0) + 16) < 0.5)
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == baseline)
            #expect(!undo.canUndo)
            let limited = try await client.callTool(name: "match_loudness", arguments: [
                "clipIds": .array([.string(audio.id)]), "targetLUFS": .double(14),
            ])
            #expect(limited.isError != true)
            #expect((try json(limited.content)["warnings"] as? [String])?.count == 1)
            #expect(harness.editor.clipFor(id: audio.id)?.loudnessGainDB == 24)
            _ = try await client.callTool(name: "undo")
            #expect(harness.editor.timeline == baseline)
            #expect(!undo.canUndo)
        } catch {
            await server.stop()
            await client.disconnect()
            if let reviewURL { await TimelineRenderer.removeTemporaryRender(reviewURL) }
            try await AudioFinishingFixtures.remove(directory)
            throw error
        }
        await server.stop()
        await client.disconnect()
        if let reviewURL { await TimelineRenderer.removeTemporaryRender(reviewURL) }
        try await AudioFinishingFixtures.remove(directory)
    }

    private func text(_ blocks: [Tool.Content]) throws -> String {
        for block in blocks { if case .text(let text, _, _) = block { return text } }
        throw CocoaError(.coderReadCorrupt)
    }

    private func json(_ blocks: [Tool.Content]) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text(blocks).utf8)) as? [String: Any])
    }
}
