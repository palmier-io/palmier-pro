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
