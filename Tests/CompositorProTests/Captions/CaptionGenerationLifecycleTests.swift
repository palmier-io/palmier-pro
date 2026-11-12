import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("Caption generation lifecycle")
@MainActor
struct CaptionGenerationLifecycleTests {
    @Test func admittedGenerationDrainsBeforeCloseAndNewGenerationRefuses() async throws {
        try await withCaptionEditor { editor, gate, _, undo in
            let before = editor.timeline
            let operation = Task { try await editor.generateCaptions(for: .init(autoDetect: true)) }
            await gate.started.wait()
            let coordinator = editor.projectPackageCoordinator
            let close = try #require(coordinator.beginClosing())
            #expect(!coordinator.canFinishClosing)
            let refused = await Task { try await editor.generateCaptions(for: .init(sourceClipIds: ["missing"])) }.result
            if case .failure(let error) = refused { #expect(error is CancellationError) }
            else { Issue.record("Closing project accepted new caption generation") }
            #expect(editor.timeline == before)
            #expect(!undo.canUndo)
            gate.release.signal()
            let ids = try await operation.value
            #expect(!ids.isEmpty)
            try await coordinator.waitUntilIdle(for: close)
            #expect(coordinator.canFinishClosing)
            coordinator.cancelClosing(close)
            undo.undo()
            #expect(editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func canceledGenerationRetainsOwnershipUntilTranscriptionDrains() async throws {
        try await withCaptionEditor { editor, gate, _, undo in
            let before = editor.timeline
            let operation = Task { try await editor.generateCaptions(for: .init(autoDetect: true)) }
            await gate.started.wait()
            let coordinator = editor.projectPackageCoordinator
            let close = try #require(coordinator.beginClosing())
            operation.cancel()
            #expect(!coordinator.canFinishClosing)
            gate.release.signal()
            #expect(await operation.result.isFailure)
            try await coordinator.waitUntilIdle(for: close)
            #expect(coordinator.canFinishClosing)
            #expect(editor.timeline == before)
            #expect(!undo.canUndo)
            coordinator.cancelClosing(close)
        }
    }

    @Test func restoredSourceURLDoesNotAllowStaleCaptionPlacement() async throws {
        try await withCaptionEditor { editor, gate, asset, undo in
            let before = editor.timeline
            let operation = Task { try await editor.generateCaptions(for: .init(autoDetect: true)) }
            await gate.started.wait()
            let original = asset.url
            asset.url = original.appendingPathExtension("replacement")
            asset.url = original
            gate.release.signal()
            #expect(await operation.result.isFailure)
            #expect(editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test func suspendedMutationRevalidatesBeforeCaptionPlacement() async throws {
        try await withCaptionEditor { editor, transcript, _, undo in
            transcript.release.signal()
            let started = PackageTestSignal()
            let release = PackageTestSignal()
            let operation = Task {
                try await editor.generateCaptions(for: .init(autoDetect: true), applying: { place in
                    started.signal()
                    await release.wait()
                    return try place()
                })
            }
            await started.wait()
            editor.timeline.tracks[0].clips[0].startFrame = 1
            let edited = editor.timeline
            release.signal()
            #expect(await operation.result.isFailure)
            #expect(editor.timeline == edited)
            #expect(!undo.canUndo)
        }
    }

    @Test func nativeStartReservesBeforeSchedulingAndFinishesBeforeCallback() async throws {
        try await withCaptionEditor { editor, gate, _, undo in
            let controller = editor.captionGenerationController
            let before = editor.timeline
            var completions = 0
            controller.start(in: editor, request: .init(autoDetect: true), mode: .captions) { output in
                #expect(!controller.isGenerating)
                if case .captions(let ids) = output { #expect(!ids.isEmpty) }
                else { Issue.record("Expected captions") }
                completions += 1
                controller.cancel()
            }
            #expect(controller.isGenerating)
            let coordinator = editor.projectPackageCoordinator
            let close = try #require(coordinator.beginClosing())
            #expect(!coordinator.canFinishClosing)
            await gate.started.wait()
            controller.start(in: editor, request: .init(autoDetect: true), mode: .captions) { _ in
                Issue.record("Duplicate generation started")
            }
            gate.release.signal()
            await controller.waitUntilFinished()
            try await coordinator.waitUntilIdle(for: close)
            #expect(completions == 1)
            #expect(controller.note == nil)
            #expect(coordinator.canFinishClosing)
            coordinator.cancelClosing(close)
            undo.undo()
            #expect(editor.timeline == before)
        }
    }

    @Test func tabSwitchDuringDrainCannotRestartGeneration() async throws {
        try await withCaptionEditor { editor, gate, _, undo in
            let before = editor.timeline
            editor.captionGenerationController.start(in: editor, request: .init(autoDetect: true), mode: .captions) { _ in
                Issue.record("Canceled generation published output")
            }
            await gate.started.wait()
            editor.captionGenerationController.cancel()
            // A re-created tab view reads the same persistent controller.
            let returned = editor.captionGenerationController
            returned.start(in: editor, request: .init(autoDetect: true), mode: .captions) { _ in
                Issue.record("Overlapping generation started after tab switch")
            }
            #expect(returned.isGenerating)
            gate.release.signal()
            await returned.waitUntilFinished()
            #expect(!returned.isGenerating)
            #expect(editor.timeline == before)
            #expect(!undo.canUndo)
        }
    }

    @Test(arguments: [false, true])
    func nativeCancellationSuppressesLateCallbacksAndDrains(started: Bool) async throws {
        try await withCaptionEditor { editor, gate, _, undo in
            let controller = editor.captionGenerationController
            let before = editor.timeline
            controller.start(in: editor, request: .init(autoDetect: true), mode: .captions) { _ in
                Issue.record("Canceled generation published output")
            }
            if started { await gate.started.wait() }
            controller.cancel()
            let coordinator = editor.projectPackageCoordinator
            let close = try #require(coordinator.beginClosing())
            #expect(!coordinator.canFinishClosing)
            gate.release.signal()
            await controller.waitUntilFinished()
            try await coordinator.waitUntilIdle(for: close)
            #expect(!controller.isGenerating)
            #expect(controller.note == nil)
            #expect(editor.timeline == before)
            #expect(!undo.canUndo)
            coordinator.cancelClosing(close)
        }
    }

    @Test func mcpGenerationNestsAdmissionAndPersistsOneUndoableResult() async throws {
        try await withCaptionEditor { editor, gate, _, undo in
            let server = Server(name: "caption-intent", version: "1", capabilities: .init(tools: .init(listChanged: false)))
            await MCPService.registerTools(on: server, executor: ToolExecutor(editor: editor))
            let transports = await InMemoryTransport.createConnectedPair()
            let client = Client(name: "caption-intent-tests", version: "1")
            try await server.start(transport: transports.server)
            do {
                _ = try await client.connect(transport: transports.client)
                let tools = try await client.listTools()
                #expect(tools.tools.contains { $0.name == "add_captions" })
                let before = editor.timeline
                let operation = Task { try await client.callTool(name: "add_captions") }
                await gate.started.wait()
                let coordinator = editor.projectPackageCoordinator
                let close = try #require(coordinator.beginClosing())
                #expect(!coordinator.canFinishClosing)
                var saved = false
                coordinator.enqueueSave { lease in coordinator.finishSave(lease) { saved = true } }
                #expect(saved)
                let refused = try await client.callTool(name: "add_captions")
                #expect(refused.isError == true)
                #expect(editor.timeline == before)
                #expect(!undo.canUndo)
                gate.release.signal()
                let receipt = try await operation.value
                #expect(receipt.isError != true)
                try await coordinator.waitUntilIdle(for: close)
                let captions = editor.timeline.tracks[0].clips
                #expect(captions.map(\.textContent) == ["Hello"])
                #expect(captions.map(\.startFrame) == [0])
                #expect(Set(captions.map(\.id)).count == captions.count)
                coordinator.cancelClosing(close)
                let read = try await client.callTool(name: "get_timeline", arguments: ["captionDetail": .bool(true)])
                #expect(read.isError != true)
                #expect(read.content.contains { item in
                    if case .text(let text, _, _) = item { return text.contains(captions[0].id.prefix(8)) && text.contains("Hello") }
                    return false
                })
                let undone = try await client.callTool(name: "undo")
                #expect(undone.isError != true)
                #expect(editor.timeline == before)
                #expect(!undo.canUndo)
                undo.redo()
                #expect(editor.timeline.tracks[0].clips == captions)
                await client.disconnect()
                await server.stop()
            } catch {
                gate.release.signal()
                await client.disconnect()
                await server.stop()
                throw error
            }
        }
    }

    private func withCaptionEditor(
        _ body: @MainActor (EditorViewModel, CaptionTranscriptGate, MediaAsset, UndoManager) async throws -> Void
    ) async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            let url = try await fixture.stage()
            let asset = MediaAsset(id: UUID().uuidString, url: url, type: .audio, name: "Voice", duration: 3)
            editor.importMediaAsset(asset)
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [
                Fixtures.clip(mediaRef: asset.id, mediaType: .audio, start: 0, duration: 90),
            ])])
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)
            let gate = CaptionTranscriptGate()
            editor.captionTranscriptionService = CaptionTranscriptionService { _ in
                await gate.load()
            }
            try await body(editor, gate, asset, undo)
            try await savePackageTestDocument(document)
            #expect(try await fixture.readPackage().projectFile.timelines == editor.timelines)
        }
    }
}

@MainActor
final class CaptionTranscriptGate {
    let started = PackageTestSignal()
    let release = PackageTestSignal()

    func load() async -> TranscriptionResult {
        started.signal()
        await release.wait()
        return TranscriptionResult(text: "Hello", language: "en", words: [
            TranscriptionWord(text: "Hello", start: 0, end: 1),
        ], segments: [])
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { true } else { false }
    }
}
