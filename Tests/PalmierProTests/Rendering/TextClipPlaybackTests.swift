import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Text clip playback", .serialized)
@MainActor
struct TextClipPlaybackTests {
    @Test func addingTextAtTimelineEndExtendsPreviewComposition() async throws {
        var existingText = Fixtures.clip(
            id: "existing-text",
            mediaRef: "",
            mediaType: .text,
            start: 0,
            duration: 30
        )
        existingText.textContent = "Existing"

        let editor = EditorViewModel()
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)
        editor.timeline = Fixtures.timeline(
            fps: 30,
            tracks: [Fixtures.videoTrack(clips: [existingText])]
        )
        editor.timeline.width = 64
        editor.timeline.height = 64

        let engine = VideoEngine(editor: editor)
        editor.videoEngine = engine
        defer {
            engine.teardown()
            editor.videoEngine = nil
        }

        engine.rebuild()
        try await #require(engine.rebuildTask).value
        let initialItem = try #require(engine.player.currentItem)
        let initialDuration = try await initialItem.asset.load(.duration)
        #expect(CMTimeCompare(initialDuration, CMTime(value: 30, timescale: 30)) == 0)

        editor.currentFrame = 30
        let addedClipId = try #require(editor.addTextClip())
        try await #require(engine.rebuildTask).value

        let updatedItem = try #require(engine.player.currentItem)
        let updatedDuration = try await updatedItem.asset.load(.duration)
        #expect(CMTimeCompare(updatedDuration, CMTime(value: 120, timescale: 30)) == 0)
        let instructions = try #require(updatedItem.videoComposition).instructions
            .compactMap { $0 as? CompositorInstruction }
        #expect(instructions.contains { instruction in
            instruction.layers.contains { $0.clip.id == addedClipId }
        })

        #expect(editor.undo.undoLatest() == "Add Text")
        try await #require(engine.rebuildTask).value

        let restoredItem = try #require(engine.player.currentItem)
        let restoredDuration = try await restoredItem.asset.load(.duration)
        #expect(CMTimeCompare(restoredDuration, CMTime(value: 30, timescale: 30)) == 0)
        let restoredInstructions = try #require(restoredItem.videoComposition).instructions
            .compactMap { $0 as? CompositorInstruction }
        #expect(restoredInstructions.allSatisfy { instruction in
            instruction.layers.allSatisfy { $0.clip.id != addedClipId }
        })

        undoManager.redo()
        try await #require(engine.rebuildTask).value

        let redoneItem = try #require(engine.player.currentItem)
        let redoneDuration = try await redoneItem.asset.load(.duration)
        #expect(CMTimeCompare(redoneDuration, CMTime(value: 120, timescale: 30)) == 0)
        let redoneInstructions = try #require(redoneItem.videoComposition).instructions
            .compactMap { $0 as? CompositorInstruction }
        #expect(redoneInstructions.contains { instruction in
            instruction.layers.contains { $0.clip.id == addedClipId }
        })
    }
}
