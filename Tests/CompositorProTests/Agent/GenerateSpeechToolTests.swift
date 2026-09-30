import AVFoundation
import Foundation
import MCP
import Testing
@testable import CompositorPro

@Suite("generate_speech", .serialized)
@MainActor
struct GenerateSpeechToolTests {
    @Test func speaksTextIntoTheLibraryAndReportsTheVoice() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)

        let result = try await executor.execute(name: "generate_speech", args: [
            "text": "The timeline is ready for review.",
        ], source: "test")
        let receipt = try json(receiptText(result))

        let mediaRef = try #require(receipt["mediaRef"] as? String)
        #expect(receipt["status"] as? String == "ready")
        #expect(receipt["source"] as? String == "text")
        #expect((receipt["voice"] as? String)?.isEmpty == false)

        // The receipt must point at a real asset with real audio behind it.
        let asset = try #require(fixture.editor.mediaAssets.first { $0.id.hasPrefix(mediaRef) })
        #expect(asset.type == .audio)
        // The asset must point at real audio that outlives the render, not at a temp file.
        #expect(FileManager.default.fileExists(atPath: asset.url.path))
        #expect(try AVAudioFile(forReading: asset.url).length > 0)
        #expect(asset.url.path.hasPrefix(fixture.editor.projectURL?.path ?? ""))

        let notes = try #require(receipt["notes"] as? [String])
        #expect(notes.contains { $0.contains("no credits") })
    }

    @Test func placesOnItsOwnTrackAsOneUndoableAction() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)
        let tracksBefore = fixture.editor.timeline.tracks.count

        let result = try await executor.execute(name: "generate_speech", args: [
            "text": "Placed voiceover.",
            "placeAtFrame": 48,
            "trackName": "Narration",
        ], source: "test")
        let receipt = try json(receiptText(result))

        #expect(fixture.editor.timeline.tracks.count == tracksBefore + 1)
        let track = try #require(fixture.editor.timeline.tracks.last)
        #expect(track.type == .audio)
        #expect(track.name == "Narration")
        let clip = try #require(track.clips.first)
        #expect(clip.startFrame == 48)

        fixture.undoManager.undo()
        #expect(fixture.editor.timeline.tracks.count == tracksBefore)
    }

    @Test func anUnknownVoiceIsRefusedWithCandidates() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)

        let result = try await executor.execute(name: "generate_speech", args: [
            "text": "hello",
            "voice": "Definitely Not A Voice",
        ], source: "test")
        let message = try receiptText(result)
        #expect(message.contains("No installed voice matches"))
        #expect(fixture.editor.mediaAssets.isEmpty)
    }

    @Test func anEmptyRequestNamesBothWaysToSupplyWords() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)

        let result = try await executor.execute(name: "generate_speech", args: [:], source: "test")
        #expect(try receiptText(result).contains("pass text to speak"))
    }

    @Test func outOfRangeRateIsRefusedBeforeRendering() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)

        let result = try await executor.execute(name: "generate_speech", args: [
            "text": "hello",
            "rate": 9,
        ], source: "test")
        #expect(try receiptText(result).contains("rate must be 0.5–2.0"))
        #expect(fixture.editor.mediaAssets.isEmpty)
    }

    @Test func aClipIdAloneIsNotMistakenForPassingBothScopeArguments() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let executor = ToolExecutor(editor: fixture.editor)

        // Regression: collecting the optional scope arguments into a dictionary and compacting
        // them yields `.some(nil)`, so an absent trackIndex read as present and every
        // transcript request was refused as "pass either clipId or trackIndex, not both".
        let result = try await executor.execute(name: "generate_speech", args: [
            "clipId": "missing",
        ], source: "test")
        let message = try receiptText(result)
        #expect(!message.contains("not both"))
        #expect(message.contains("not found"))
    }

    @Test func schemaIsAdvertisedWithNoRequiredKeys() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .generateSpeech })
        let properties = tool.mcpSchemaValue.objectValue?["properties"]?.objectValue
        #expect(properties?["text"] != nil)
        #expect(properties?["voice"] != nil)
        #expect(properties?["placeAtFrame"] != nil)
    }

    // MARK: - Fixture

    private struct Fixture {
        let editor: EditorViewModel
        let root: URL
        let undoManager: UndoManager
    }

    private func makeFixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("generate-speech-\(UUID().uuidString)", isDirectory: true)
        let editor = EditorViewModel()
        editor.projectURL = root.appendingPathComponent("Speech.palmier", isDirectory: true)
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)
        return Fixture(editor: editor, root: root, undoManager: undoManager)
    }

    private func cleanup(_ fixture: Fixture) {
        let root = fixture.root
        Task.detached { try? FileManager.default.removeItem(at: root) }
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func receiptText(_ result: ToolResult) throws -> String {
        for block in result.content {
            if case .text(let value) = block { return value }
        }
        throw CocoaError(.coderReadCorrupt)
    }
}
