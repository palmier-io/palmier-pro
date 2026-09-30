import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("generate_drone", .serialized)
@MainActor
struct GenerateDroneToolTests {
    /// Regression: the rendered drone was pointed at a temporary file that the tool then
    /// deleted, so the asset it placed on the timeline resolved to nothing.
    @Test func thePlacedClipResolvesToAudioThatStillExists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("generate-drone-\(UUID().uuidString)", isDirectory: true)
        defer { Task.detached { try? FileManager.default.removeItem(at: root) } }

        let editor = EditorViewModel()
        editor.projectURL = root.appendingPathComponent("Drone.palmier", isDirectory: true)
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)

        let result = try await ToolExecutor(editor: editor).execute(
            name: "generate_drone",
            args: ["tonic": "C", "duration": 1],
            source: "test"
        )
        #expect(!result.isError)

        let clip = try #require(editor.timeline.tracks.first?.clips.first)
        let asset = try #require(editor.mediaAssets.first { $0.id == clip.mediaRef })
        #expect(asset.type == .audio)
        #expect(FileManager.default.fileExists(atPath: asset.url.path))
        #expect(asset.url.path.hasPrefix(editor.projectURL?.path ?? ""))
        #expect(try AVAudioFile(forReading: asset.url).length > 0)
    }
}
