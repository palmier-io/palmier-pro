import AppKit
import Testing
@testable import CompositorPro

@Suite("Editor split layout intent")
@MainActor
struct EditorSplitLayoutIntentTests {

    // Headless NSHostingControllers crash SwiftUI when several are created per process;
    // one controller covers all queued-intent scenarios.
    @Test func queuedLayoutAndCollapseIntentsApplyLatestRequest() {
        let previous = WorkspaceLayoutStore.shared.selection
        WorkspaceLayoutStore.shared.selection = .default
        defer { WorkspaceLayoutStore.shared.selection = previous }
        let editor = EditorViewModel()
        let controller = EditorSplitViewController(editor: editor)
        _ = controller.view

        // Collapse intent: newest request wins, matching requests don't queue.
        guard let mediaItem = controller.leafItem(for: .media) else {
            Issue.record("media split item missing")
            return
        }
        #expect(!mediaItem.isCollapsed)
        controller.applyCollapsed(item: mediaItem, collapsed: true)
        #expect(controller.pendingCollapse[ObjectIdentifier(mediaItem)] == true)
        controller.applyCollapsed(item: mediaItem, collapsed: true)
        #expect(controller.pendingCollapse[ObjectIdentifier(mediaItem)] == true, "same intent must not duplicate")
        controller.applyCollapsed(item: mediaItem, collapsed: false)
        #expect(controller.pendingCollapse[ObjectIdentifier(mediaItem)] == false, "newest intent wins")
        controller.flushPendingCollapses()
        #expect(mediaItem.isCollapsed == false)
        #expect(controller.pendingCollapse.isEmpty)
        controller.applyCollapsed(item: mediaItem, collapsed: mediaItem.isCollapsed)
        #expect(controller.pendingCollapse.isEmpty, "matching collapse must not queue")

        // Layout intent: the latest scheduled preset is the one that builds.
        controller.applyLayoutIfNeeded(.media)
        #expect(controller.scheduledPreset == .media)
        controller.applyLayoutIfNeeded(.vertical)
        #expect(controller.scheduledPreset == .vertical)
        controller.flushScheduledLayout()
        #expect(controller.currentPreset == .vertical)
        #expect(controller.scheduledPreset == nil)
        controller.applyLayoutIfNeeded(.vertical)
        #expect(controller.scheduledPreset == nil, "matching preset must not queue a rebuild")

        // Maximizing then switching presets drops the maximized state.
        controller.applyMaximize(.agent)
        controller.applyLayoutIfNeeded(.media)
        controller.flushScheduledLayout()
        #expect(controller.currentPreset == .media)
        #expect(editor.maximizedPanel == nil)
    }
}
