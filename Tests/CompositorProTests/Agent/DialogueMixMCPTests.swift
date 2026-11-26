import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Measured mixing through MCP")
@MainActor
struct DialogueMixMCPTests {
    @Test func discoversMixesReadsBackRetriesPersistsAndUndoes() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let editor = DialogueMixFixtures.editor(source: directory.appendingPathComponent("tone.wav"))
        editor.timeline.tracks[0].clips[0].volume = 20
        let before = editor.timeline
        let manager = UndoManager()
        editor.undo.attach(manager)
        let executor = ToolExecutor(editor: editor, audioMixFinishing: DialogueMixFixtures.finish)
        let server = Server(name: "dialogue-mix", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let transports = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "dialogue-mix-test", version: "1")
        try await server.start(transport: transports.server)
        do {
            _ = try await client.connect(transport: transports.client)
            let (tools, _) = try await client.listTools()
            let tool = try #require(tools.first { $0.name == "mix_audio" })
            #expect(tool.inputSchema.objectValue?["required"]?.arrayValue?.contains(.string("roles")) == true)
            let initialRead = try json(try await client.callTool(name: "get_timeline").content)
            let initialTracks = try #require(initialRead["tracks"] as? [[String: Any]])
            let initialVoice = try #require((initialTracks[0]["clips"] as? [[String: Any]])?.first)
            #expect(abs((initialVoice["volumeDb"] as? Double ?? 0) - 20 * log10(20)) < 0.001)
            let roles: [Value] = [
                .object(["clipId": .string("voice"), "role": .string("voice")]),
                .object(["clipId": .string("music"), "role": .string("music")]),
                .object(["clipId": .string("room"), "role": .string("ambience")]),
            ]
            let args: [String: Value] = ["roles": .array(roles), "targetLUFS": .double(-16), "truePeakDBTP": .double(-1), "bedFadeFrames": .int(6)]
            var invalid = args
            invalid["bedFadeFrames"] = .double(0.5)
            #expect(try await client.callTool(name: "mix_audio", arguments: invalid).isError == true)
            invalid = args
            invalid["roles"] = .array([.object(["clipId": .string("voice"), "role": .string("voice"), "unexpected": .bool(true)])])
            #expect(try await client.callTool(name: "mix_audio", arguments: invalid).isError == true)
            #expect(editor.timeline == before)
            #expect(!manager.canUndo)

            let result = try await client.callTool(name: "mix_audio", arguments: args)
            try #require(result.isError != true)
            let receipt = try json(result.content)
            #expect(receipt["changed"] as? Bool == true)
            #expect(receipt["noOp"] as? Bool == false)
            #expect((receipt["speechBalance"] as? [String: Any])?["passes"] as? Bool == true)
            let mixed = editor.timeline
            let state = try #require(mixed.audioMix)
            #expect(state.request.target.accepts(state.measurement))
            let read = try await client.callTool(name: "get_timeline")
            let stored = try #require(try json(read.content)["audioMix"] as? [String: Any])
            #expect(stored["outputRevision"] as? String == state.outputRevision)
            #expect((stored["ownedVolumeTracks"] as? [String: Any])?["music"] != nil)
            #expect(try await DialogueMixFixtures.persisted(mixed, directory: directory) == mixed)
            let measured = try await AudioMixAnalyzer.measure(timeline: mixed, timelines: [], urls: editor.mediaResolver.expectedURLMap())
            #expect(state.request.target.accepts(measured))
            let retry = try await client.callTool(name: "mix_audio", arguments: args)
            #expect(try json(retry.content)["noOp"] as? Bool == true)
            #expect(editor.timeline == mixed)
            _ = try await client.callTool(name: "undo")
            #expect(editor.timeline == before)
            #expect(!manager.canUndo)
        } catch {
            await server.stop()
            await client.disconnect()
            try await AudioFinishingFixtures.remove(directory)
            throw error
        }
        await server.stop()
        await client.disconnect()
        try await AudioFinishingFixtures.remove(directory)
    }

    private func json(_ content: [Tool.Content]) throws -> [String: Any] {
        for block in content {
            if case .text(let value, _, _) = block {
                return try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
            }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
