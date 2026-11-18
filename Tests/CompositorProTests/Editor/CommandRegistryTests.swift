import Foundation
import Testing
@testable import CompositorPro

@Suite("Command registry")
@MainActor
struct CommandRegistryTests {
    @Test func commandsHaveUniqueIDsAndTitles() {
        let ids = CommandRegistry.commands.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(CommandRegistry.commands.allSatisfy { !$0.titleKey.isEmpty })
    }

    @Test func searchMatchesTitleAndIdentifier() {
        #expect(CommandRegistry.matches("zoom").map(\.id) == [.fitTimeline, .zoomSelection])
        #expect(CommandRegistry.matches("RIPPLE").map(\.id) == [.toggleRipple])
        #expect(CommandRegistry.matches("splitAtPlayhead").map(\.id) == [.splitAtPlayhead])
        #expect(CommandRegistry.matches("no such action").isEmpty)
        #expect(CommandRegistry.matches("").count == CommandRegistry.commands.count)
    }

    @Test func performingCommandsMutatesEditorState() {
        let harness = ToolHarness()
        harness.editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "a", start: 0, duration: 90)]),
        ])
        harness.editor.timelineVisibleWidth = 900

        let rippleBefore = harness.editor.rippleEditingEnabled
        CommandRegistry.perform(.toggleRipple, editor: harness.editor)
        #expect(harness.editor.rippleEditingEnabled != rippleBefore)

        let linkedBefore = harness.editor.linkedSelectionEnabled
        CommandRegistry.perform(.toggleLinkedSelection, editor: harness.editor)
        #expect(harness.editor.linkedSelectionEnabled != linkedBefore)

        harness.editor.selectedClipIds = ["a"]
        CommandRegistry.perform(.clearSelection, editor: harness.editor)
        #expect(harness.editor.selectedClipIds.isEmpty)

        CommandRegistry.perform(.fitTimeline, editor: harness.editor)
        #expect(harness.editor.zoomScale > 0)
    }
}

@Suite("Keyframe editing commands")
@MainActor
struct KeyframeEditingCommandTests {
    private func harness() -> ToolHarness {
        let harness = ToolHarness()
        var clip = Fixtures.clip(id: "k", start: 0, duration: 120)
        clip.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0), Keyframe(frame: 30, value: 1),
        ])
        harness.editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        harness.editor.selectedClipIds = ["k"]
        return harness
    }

    @Test func nudgingMovesTheKeyframeAtThePlayhead() {
        let harness = harness()
        harness.editor.playheadState.timelineFrame = 30
        #expect(harness.editor.selectionHasKeyframe(at: 30))
        #expect(harness.editor.nudgeSelectedKeyframes(at: 30, by: 5))
        #expect(harness.editor.keyframeFrames(clipId: "k", property: .opacity) == [0, 35])
    }

    @Test func nudgingWithNothingAtThePlayheadIsANoOp() {
        let harness = harness()
        harness.editor.playheadState.timelineFrame = 90
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        #expect(!harness.editor.nudgeSelectedKeyframes(at: 90, by: 3))
        #expect(!undo.canUndo)
        #expect(harness.editor.keyframeFrames(clipId: "k", property: .opacity) == [0, 30])
    }

    @Test func removingKeyframesAtThePlayheadIsOneUndoAction() {
        let harness = harness()
        let undo = UndoManager()
        harness.editor.undo.attach(undo)
        #expect(harness.editor.removeSelectedKeyframes(at: 30))
        #expect(harness.editor.keyframeFrames(clipId: "k", property: .opacity) == [0])
        undo.undo()
        #expect(harness.editor.keyframeFrames(clipId: "k", property: .opacity) == [0, 30])
    }

    @Test func paletteExposesKeyframeCommands() {
        let ids = CommandRegistry.matches("keyframe").map(\.id)
        #expect(ids.contains(.nudgeKeyframesLeft))
        #expect(ids.contains(.nudgeKeyframesRight))
        #expect(ids.contains(.removeKeyframes))
    }
}
