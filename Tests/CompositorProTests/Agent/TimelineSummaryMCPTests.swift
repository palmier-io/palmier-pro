import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("MCP timeline coverage reads")
@MainActor
struct TimelineSummaryMCPTests {
    @Test func windowedReadsReportOnlyIntersectingGapFrames() async throws {
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "a", start: 0, duration: 50),
                Fixtures.clip(id: "b", start: 100, duration: 50),
                Fixtures.clip(id: "c", start: 200, duration: 50),
            ]),
        ]))
        let before = harness.editor.timeline
        try await withClient(harness) { client in
            let whole = try await read(client, [:])
            let fullTracks = try #require(whole["tracks"] as? [[String: Any]])
            #expect(fullTracks[0]["gaps"] as? [[Int]] == [[50, 100], [150, 200]])
            let window = try await read(client, ["startFrame": .int(90), "endFrame": .int(160)])
            let tracks = try #require(window["tracks"] as? [[String: Any]])
            #expect(tracks[0]["gaps"] as? [[Int]] == [[90, 100], [150, 160]])
            let clips = try #require(tracks[0]["clips"] as? [[String: Any]])
            #expect(clips.map { $0["id"] as? String } == ["b"])
            #expect(harness.editor.timeline == before)
        }
    }

    @Test func summaryPreservesCoverageAndReducesLongTimelinePayload() async throws {
        let captions = (0..<740).map { index in
            var clip = Fixtures.clip(id: "caption-\(index)", mediaType: .text, start: index * 74, duration: 74)
            clip.captionGroupId = "captions"
            clip.textContent = "Narration sentence \(index)"
            return clip
        }
        let shots = (0..<74).map { Fixtures.clip(id: "shot-\($0)", start: $0 * 730, duration: 700) }
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: captions),
            Fixtures.videoTrack(clips: shots),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "narration", mediaType: .audio, start: 0, duration: 54_802)]),
        ]))
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        let before = harness.editor.timeline
        try await withClient(harness) { client in
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "get_timeline" })
            #expect(tool.inputSchema.objectValue?["properties"]?.objectValue?["summary"]?.objectValue?["type"] == .string("boolean"))

            let detailed = try await read(client, [:])
            let detailedTracks = try #require(detailed["tracks"] as? [[String: Any]])
            let summary = try await read(client, ["summary": .bool(true)])
            let tracks = try #require(summary["tracks"] as? [[String: Any]])
            #expect(summary["totalFrames"] as? Int == 54_802)
            #expect(tracks.map { $0["clipCount"] as? Int } == [740, 74, 1])
            #expect(tracks.map { $0["trackId"] as? String } == detailedTracks.map { $0["trackId"] as? String })
            #expect(tracks[1]["gaps"] as? [[Int]] == detailedTracks[1]["gaps"] as? [[Int]])
            #expect(tracks.allSatisfy { $0["clips"] == nil })
            let groups = try #require(tracks[0]["captionGroups"] as? [[String: Any]])
            #expect(groups[0]["clipCount"] as? Int == 740)
            #expect(groups[0]["frameRange"] as? [Int] == [0, 54_760])
            let fullBytes = try JSONSerialization.data(withJSONObject: detailed).count
            let summaryBytes = try JSONSerialization.data(withJSONObject: summary).count
            #expect(summaryBytes * 3 < fullBytes)
            print("Timeline coverage payload: detailed=\(fullBytes) bytes, summary=\(summaryBytes) bytes (740 captions, 74 shots).")

            let clock = ContinuousClock()
            let fullStart = clock.now
            for _ in 0..<20 { _ = try await client.callTool(name: "get_timeline") }
            let fullTime = fullStart.duration(to: clock.now)
            let summaryStart = clock.now
            for _ in 0..<20 { _ = try await client.callTool(name: "get_timeline", arguments: ["summary": .bool(true)]) }
            let summaryTime = summaryStart.duration(to: clock.now)
            print("Timeline coverage benchmark, 20 reads: detailed=\(fullTime), summary=\(summaryTime).")
            #expect(harness.editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func invalidSummaryOptionsDoNotMutateTheTimeline() async throws {
        let harness = ToolHarness()
        let before = harness.editor.timeline
        try await withClient(harness) { client in
            for value in [Value.int(1), .string("true")] {
                let result = try await client.callTool(name: "get_timeline", arguments: ["summary": value])
                #expect(result.isError == true)
                #expect(harness.editor.timeline == before)
            }
            let mixed = try await client.callTool(name: "get_timeline", arguments: ["summary": .bool(true), "captionDetail": .bool(true)])
            #expect(mixed.isError == true)
            let omitted = try await read(client, ["summary": .null])
            #expect(omitted["summary"] == nil)
            #expect(harness.editor.timeline == before)
        }
    }

    private func read(_ client: Client, _ arguments: [String: Value]) async throws -> [String: Any] {
        let result = try await client.callTool(name: "get_timeline", arguments: arguments)
        try #require(result.isError != true)
        let content = try #require(result.content.first)
        guard case .text(let text, _, _) = content else { throw CocoaError(.coderReadCorrupt) }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func withClient(_ harness: ToolHarness, _ operation: (Client) async throws -> Void) async throws {
        let server = Server(name: "timeline-coverage", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "timeline-coverage-tests", version: "1")
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
