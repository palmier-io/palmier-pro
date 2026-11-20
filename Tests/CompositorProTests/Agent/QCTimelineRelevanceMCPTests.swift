import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("MCP QC report relevance")
@MainActor
struct QCTimelineRelevanceMCPTests {
    @Test func captionPausesAndMutedAudioDoNotObscureVisualGaps() async throws {
        var captions = [
            Fixtures.clip(id: "caption-a", mediaType: .text, start: 0, duration: 30),
            Fixtures.clip(id: "caption-b", mediaType: .text, start: 60, duration: 30),
        ]
        for index in captions.indices {
            captions[index].captionGroupId = "captions"
            captions[index].textContent = "Caption"
        }
        let voice = Fixtures.clip(id: "voice", mediaType: .audio, start: 0, duration: 120)
        var muted = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "muted-a", mediaType: .audio, start: 20, duration: 30),
            Fixtures.clip(id: "muted-b", mediaType: .audio, start: 80, duration: 20),
        ])
        muted.muted = true
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: captions),
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "shot-a", start: 0, duration: 40),
                Fixtures.clip(id: "shot-b", start: 50, duration: 70),
            ]),
            Fixtures.audioTrack(clips: [voice]),
            muted,
        ]))
        let before = harness.editor.timeline
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        try await withClient(harness) { client in
            let report = try await read(client, "qc_timeline")
            let issues = try #require(report["issues"] as? [[String: Any]])
            let gaps = issues.filter { $0["kind"] as? String == "trackGap" }
            #expect(gaps.count == 1)
            #expect(gaps.first?["trackIndex"] as? Int == 1)
            #expect(gaps.first?["startFrame"] as? Int == 40)
            #expect(gaps.first?["endFrame"] as? Int == 50)
            #expect(gaps.first?["detail"] as? String == "10 empty frames between clips on this track.")
            let fades = issues.filter { $0["kind"] as? String == "clipFadesHard" }
            #expect(fades.count == 1)
            #expect(fades.first?["clipId"] as? String == voice.id)
            let timeline = try await read(client, "get_timeline")
            let tracks = try #require(timeline["tracks"] as? [[String: Any]])
            #expect(tracks.count == 4)
            #expect(tracks[3]["muted"] as? Bool == true)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
            let repeated = try await read(client, "qc_timeline")
            #expect(repeated["warningCount"] as? Int == report["warningCount"] as? Int)
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func mutedAudioStillReportsStructuralErrorsAndUnmutingRestoresWarnings() async throws {
        var track = Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "a", mediaType: .audio, start: 10, duration: 40),
            Fixtures.clip(id: "b", mediaType: .audio, start: 30, duration: 40),
        ])
        track.muted = true
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [track]))
        try await withClient(harness) { client in
            let muted = try await read(client, "qc_timeline")
            let issues = try #require(muted["issues"] as? [[String: Any]])
            #expect(issues.contains { $0["kind"] as? String == "overlappingClips" })
            #expect(!issues.contains { $0["kind"] as? String == "clipFadesHard" || $0["kind"] as? String == "trackGap" })
            harness.editor.timeline.tracks[0].muted = false
            let audible = try await read(client, "qc_timeline")
            let restored = try #require(audible["issues"] as? [[String: Any]])
            #expect(restored.filter { $0["kind"] as? String == "clipFadesHard" }.count == 2)
            #expect(restored.contains { $0["kind"] as? String == "trackGap" && $0["startFrame"] as? Int == 0 })
        }
    }

    @Test func ordinaryTitlesAndEmptyVideoTracksRetainCoverageWarnings() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "title", mediaType: .text, start: 30, duration: 30)]),
            Fixtures.videoTrack(),
        ]))
        try await withClient(harness) { client in
            let report = try await read(client, "qc_timeline")
            let issues = try #require(report["issues"] as? [[String: Any]])
            let gaps = issues.filter { $0["kind"] as? String == "trackGap" }
            #expect(gaps.contains { $0["trackIndex"] as? Int == 0 && $0["startFrame"] as? Int == 0 && $0["endFrame"] as? Int == 30 })
            #expect(gaps.contains { $0["trackIndex"] as? Int == 1 && $0["startFrame"] as? Int == 0 && $0["endFrame"] as? Int == 60 })
        }
    }

    private func read(_ client: Client, _ name: String) async throws -> [String: Any] {
        let result = try await client.callTool(name: name)
        try #require(result.isError != true)
        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func withClient(_ harness: ToolHarness, _ operation: (Client) async throws -> Void) async throws {
        let server = Server(name: "qc-relevance", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "qc-relevance-tests", version: "1")
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
