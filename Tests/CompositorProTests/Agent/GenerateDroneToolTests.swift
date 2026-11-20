import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@Suite("generate_drone", .serialized)
@MainActor
struct GenerateDroneToolTests {
    /// Regression: the rendered drone was pointed at a temporary file that the tool then
    /// deleted, so the asset it placed on the timeline resolved to nothing.
    @Test func thePlacedClipResolvesToAudioThatStillExists() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            let undoManager = UndoManager()
            editor.undo.attach(undoManager)

            let result = try await ToolExecutor(editor: editor).execute(
                name: "generate_drone",
                args: ["tonic": "C", "duration": 1],
                source: "test"
            )
            #expect(!result.isError, "\(ToolHarness.textOf(result))")

            let clip = try #require(editor.timeline.tracks.first?.clips.first)
            let asset = try #require(editor.mediaAssets.first { $0.id == clip.mediaRef })
            #expect(asset.type == .audio)
            #expect(try await fixture.exists(asset.url))
            #expect(asset.url.path.hasPrefix(editor.projectURL?.path ?? ""))
            let url = asset.url
            #expect(try await fixture.io.perform { try AVAudioFile(forReading: url).length } > 0)
        }
    }
}
