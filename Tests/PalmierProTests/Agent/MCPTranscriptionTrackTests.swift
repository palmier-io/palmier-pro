import MCP
import Testing
@testable import PalmierPro

@Suite("MCP transcription track selection", .serialized)
@MainActor
struct MCPTranscriptionTrackTests {
    @Test func discoveryAndTrackValidationCrossMCPBoundary() async throws {
        let first = Fixtures.clip(id: "first", mediaType: .audio, start: 0, duration: 30)
        let second = Fixtures.clip(id: "second", mediaType: .audio, start: 0, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(id: "first-track", clips: [first]),
            Fixtures.audioTrack(id: "second-track", clips: [second]),
        ]))
        let server = Server(
            name: "transcription-track-test",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MCPService.registerTools(on: server, executor: harness.executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "transcription-track-test", version: "1.0.0")

        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            for name in ["get_transcript", "add_captions"] {
                let tool = try #require(tools.first { $0.name == name })
                let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
                #expect(properties["trackIndex"]?.objectValue?["type"]?.stringValue == "integer")
            }
            let captionTool = try #require(tools.first { $0.name == "add_captions" })
            let captionProperties = try #require(
                captionTool.inputSchema.objectValue?["properties"]?.objectValue
            )
            let maximumGap = try #require(captionProperties["maximumGapSeconds"]?.objectValue)
            #expect(maximumGap["type"]?.stringValue == "number")
            #expect(maximumGap["minimum"]?.intValue == 0)
            #expect(maximumGap["maximum"]?.intValue == 2)

            let transcript = try await client.callTool(
                name: "get_transcript",
                arguments: ["trackIndex": .int(1)]
            )
            #expect(transcript.isError != true)
            #expect(harness.executor.lastTranscriptSession?.scope == .track(id: "second-track"))
            #expect(harness.executor.lastTranscriptSession?.timelineId == harness.editor.activeTimelineId)

            for name in ["get_transcript", "add_captions"] {
                let invalid = try await client.callTool(
                    name: name,
                    arguments: ["trackIndex": .int(4)]
                )
                #expect(invalid.isError == true)
            }
            let invalidGap = try await client.callTool(
                name: "add_captions",
                arguments: ["maximumGapSeconds": .double(2.1)]
            )
            #expect(invalidGap.isError == true)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }
}
