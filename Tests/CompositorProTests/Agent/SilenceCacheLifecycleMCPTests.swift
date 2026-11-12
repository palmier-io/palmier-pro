import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Silence cache lifecycle through MCP", .serialized)
@MainActor
struct SilenceCacheLifecycleMCPTests {
    private func withClient(_ executor: ToolExecutor, body: (Client) async throws -> Void) async throws {
        let server = Server(name: "silence-lifecycle", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: executor)
        let pair = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "silence-lifecycle-tests", version: "1")
        try await server.start(transport: pair.server)
        do {
            _ = try await client.connect(transport: pair.client)
            try await body(client)
        } catch {
            await server.stop()
            await client.disconnect()
            throw error
        }
        await server.stop()
        await client.disconnect()
    }

    private func segmentCount(_ result: (content: [Tool.Content], isError: Bool?)) throws -> Int {
        let text = try #require(result.content.first)
        guard case .text(let json, _, _) = text else { throw CocoaError(.coderReadCorrupt) }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try #require(object["count"] as? Int)
    }

    private func editor(silent: URL, tone: URL) -> EditorViewModel {
        let editor = EditorViewModel()
        editor.mediaAssets = [MediaAsset(id: "voice", url: silent, type: .audio, name: "Voice", duration: 1)]
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "voice", mediaRef: "voice", mediaType: .audio, start: 0, duration: 30)
        ])])
        return editor
    }

    @Test func relinkedSourceIsInDeduplicatedAndDetectedAgain() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let silent = directory.appendingPathComponent("silent.wav")
        let tone = directory.appendingPathComponent("tone.wav")
        try await AudioFinishingFixtures.writeTone(to: silent, amplitudes: [0])
        try await AudioFinishingFixtures.writeTone(to: tone, amplitudes: [0.05])

        let editor = editor(silent: silent, tone: tone)
        let executor = ToolExecutor(editor: editor)

        try await withClient(executor) { client in
            let silentResult = try await client.callTool(
                name: "detect_silence", arguments: ["mediaRef": .string("voice")]
            )
            #expect(try segmentCount(silentResult) > 0)

            // Relinking must not serve the previous file's cached segments.
            editor.relinkAsset(id: "voice", to: tone)
            let toneResult = try await client.callTool(
                name: "detect_silence", arguments: ["mediaRef": .string("voice")]
            )
            #expect(try segmentCount(toneResult) == 0)
        }
    }

    @Test func sessionResetForcesADecodeOfTheSameSourceRevision() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let file = directory.appendingPathComponent("voice.wav")
        try await AudioFinishingFixtures.writeTone(to: file, amplitudes: [0])

        let editor = editor(silent: file, tone: file)
        let executor = ToolExecutor(editor: editor)

        try await withClient(executor) { client in
            let first = try await client.callTool(name: "detect_silence", arguments: ["mediaRef": .string("voice")])
            #expect(try segmentCount(first) > 0)

            // Rewriting the file keeps its identity, so only a reset can drop the cached decode.
            try await AudioFinishingFixtures.writeTone(to: file, amplitudes: [0.05])
            let cached = try await client.callTool(name: "detect_silence", arguments: ["mediaRef": .string("voice")])
            #expect(try segmentCount(cached) > 0)

            editor.mediaVisualCache.resetSessionState()
            let fresh = try await client.callTool(name: "detect_silence", arguments: ["mediaRef": .string("voice")])
            #expect(try segmentCount(fresh) == 0)
        }
    }
}