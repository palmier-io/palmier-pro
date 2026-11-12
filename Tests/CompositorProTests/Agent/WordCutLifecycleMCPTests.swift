import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Word cut lifecycle through MCP", .serialized)
@MainActor
struct WordCutLifecycleMCPTests {
    private enum Change: String, CaseIterable { case timing, trackOrder, relink, sourceRoundTrip, retiming, timeline }

    private func makeHarness() -> ToolHarness {
        let clip = Fixtures.clip(id: "voice", mediaRef: "source", mediaType: .audio, start: 0, duration: 90)
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(id: "speech", clips: [clip]), Fixtures.audioTrack(id: "other"),
        ]))
        h.editor.mediaAssets.append(MediaAsset(id: "source", url: URL(fileURLWithPath: "/tmp/word-cut-fixture.wav"), type: .audio, name: "Voice", duration: 3))
        h.executor.lastTranscriptSession = TranscriptSession(context: .init(provider: .local, preferredLocale: nil), scope: .automatic, editor: h.editor)
        return h
    }

    private nonisolated static var speech: TranscriptionResult {
        .init(text: "um hello", language: "en", words: [
            .init(text: "um", start: 0.2, end: 0.4), .init(text: "hello", start: 1, end: 1.5),
        ], segments: [])
    }

    private func withClient(_ h: ToolHarness, body: (Client) async throws -> Void) async throws {
        let server = Server(name: "word-cut-lifecycle", version: "1", capabilities: .init(tools: .init(listChanged: false)))
        await MCPService.registerTools(on: server, executor: h.executor)
        let pair = await InMemoryTransport.createConnectedPair()
        let client = Client(name: "word-cut-tests", version: "1")
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

    @Test(arguments: Change.allCases)
    private func stalePreparationCannotCutCurrentTimeline(change: Change) async throws {
        let h = makeHarness()
        let undo = UndoManager()
        h.editor.undo.attach(undo)
        let entered = PackageTestSignal(), release = PackageTestSignal()
        h.executor.transcriptLoading = { _, _, _ in
            await entered.signal()
            await release.wait()
            return Self.speech
        }
        try await withClient(h) { (client: Client) async throws in
            let pending = Task { try await client.callTool(name: "remove_words", arguments: ["words": .array([.int(0)])]) }
            await entered.wait()
            switch change {
            case .timing: h.editor.timeline.tracks[0].clips[0].startFrame = 30
            case .trackOrder: h.editor.timeline.tracks.swapAt(0, 1)
            case .relink: h.editor.mediaAssets[0].url = URL(fileURLWithPath: "/tmp/new-source.wav")
            case .sourceRoundTrip:
                let old = h.editor.mediaAssets[0].url
                h.editor.mediaAssets[0].url = URL(fileURLWithPath: "/tmp/temporary-source.wav")
                h.editor.mediaAssets[0].url = old
            case .retiming: h.editor.timeline.tracks[0].clips[0].freezeFrames = 10
            case .timeline:
                let next = Fixtures.timeline()
                h.editor.timelines.append(next)
                h.editor.activateTimeline(next.id)
            }
            let current = h.editor.timeline
            release.signal()
            let result = try await pending.value
            #expect(result.isError == true)
            #expect(h.editor.timeline == current)
            #expect(!undo.canUndo)
            let readback = try await client.callTool(name: "get_timeline")
            #expect(readback.isError != true)
            #expect(h.editor.timeline == current)
        }
    }

    @Test func successfulCutHasIndependentReadbackAndOneUndo() async throws {
        let h = makeHarness()
        let undo = UndoManager()
        h.editor.undo.attach(undo)
        h.executor.transcriptLoading = { _, _, _ in Self.speech }
        let before = h.editor.timeline
        try await withClient(h) { (client: Client) async throws in
            let cut = try await client.callTool(name: "remove_words", arguments: ["words": .array([.int(0)])])
            #expect(cut.isError != true)
            #expect(h.editor.timeline != before)
            let readback = try await client.callTool(name: "get_timeline")
            #expect(readback.isError != true)
            #expect(undo.canUndo)
            let reverted = try await client.callTool(name: "undo")
            #expect(reverted.isError != true)
            #expect(h.editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func getTranscriptRejectsStalePublication() async throws {
        let h = makeHarness()
        h.executor.lastTranscriptSession = nil
        let entered = PackageTestSignal(), release = PackageTestSignal()
        h.executor.transcriptLoading = { _, _, _ in
            await entered.signal()
            await release.wait()
            return Self.speech
        }
        try await withClient(h) { (client: Client) async throws in
            let pending = Task { try await client.callTool(name: "get_transcript") }
            await entered.wait()
            h.editor.timeline.tracks.swapAt(0, 1)
            release.signal()
            #expect(try await pending.value.isError == true)
            #expect(h.executor.lastTranscriptSession == nil)
        }
    }

    @Test func cancellationAndUnrelatedPropertiesPreserveTheirSemantics() async {
        let h = makeHarness()
        let undo = UndoManager()
        h.editor.undo.attach(undo)
        let entered = PackageTestSignal(), release = PackageTestSignal()
        h.executor.transcriptLoading = { _, _, _ in
            await entered.signal()
            await release.wait()
            return Self.speech
        }
        let before = h.editor.timeline
        let pending = Task { await h.runRaw("remove_words", args: ["matches": ["um"]]) }
        await entered.wait()
        pending.cancel()
        release.signal()
        #expect(await pending.value.isError)
        #expect(h.editor.timeline == before && !undo.canUndo)
        let session = h.executor.lastTranscriptSession!
        h.editor.timeline.tracks[0].clips[0].volume = 0.5
        #expect(session.hasSameWordMapping(in: h.editor))
    }
}
