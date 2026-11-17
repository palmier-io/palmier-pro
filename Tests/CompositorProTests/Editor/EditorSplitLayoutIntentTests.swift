import AppKit
import Testing
@testable import CompositorPro

@Suite("Editor split layout intent")
@MainActor
struct EditorSplitLayoutIntentTests {

    // Headless NSHostingControllers crash SwiftUI when several are created per process;
    // one controller covers all queued-intent scenarios.
    @Test func queuedLayoutAndCollapseIntentsApplyLatestRequest() throws {
        let previous = WorkspaceLayoutStore.shared.selection
        WorkspaceLayoutStore.shared.selection = .default
        defer { WorkspaceLayoutStore.shared.selection = previous }
        let editor = EditorViewModel()
        let controller = EditorSplitViewController(editor: editor)
        _ = controller.view
        let panels: [EditorViewModel.FocusedPanel] = [.agent, .media, .preview, .inspector, .timeline]
        let panelControllers = panels.compactMap { controller.leafItem(for: $0)?.viewController }
        #expect(panelControllers.count == panels.count)

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

        controller.applyLayoutIfNeeded(.studio)
        controller.flushScheduledLayout()
        #expect(controller.currentPreset == .studio)
        for (panel, hosted) in zip(panels, panelControllers) {
            #expect(controller.leafItem(for: panel)?.viewController === hosted)
        }

        let studio = try #require(controller.splitViewItems.last?.viewController as? NSSplitViewController)
        #expect(studio.splitView.isVertical)
        #expect(studio.splitViewItems.count == 2)
        let sidebarItem = try #require(studio.splitViewItems.last)
        let sidebar = try #require(sidebarItem.viewController as? NSSplitViewController)
        let center = try #require(studio.splitViewItems.first?.viewController as? NSSplitViewController)
        #expect(!sidebar.splitView.isVertical)
        #expect(!center.splitView.isVertical)
        #expect(controller.leafItem(for: .media)?.viewController.parent === sidebar)
        #expect(controller.leafItem(for: .inspector)?.viewController.parent === sidebar)
        #expect(controller.leafItem(for: .preview)?.viewController.parent === center)
        #expect(controller.leafItem(for: .timeline)?.viewController.parent === center)

        editor.mediaPanelVisible = false
        editor.inspectorPanelVisible = false
        controller.applyMediaVisibility(false)
        controller.applyInspectorVisibility(false)
        controller.flushPendingCollapses()
        #expect(sidebarItem.isCollapsed)
        editor.mediaPanelVisible = true
        controller.applyMediaVisibility(true)
        controller.flushPendingCollapses()
        #expect(!sidebarItem.isCollapsed)
        #expect(controller.leafItem(for: .media)?.isCollapsed == false)
        #expect(controller.leafItem(for: .inspector)?.isCollapsed == true)
    }
}
