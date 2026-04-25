import AppKit
import SwiftUI

struct EditorView: NSViewControllerRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSViewController(context: Context) -> EditorSplitViewController {
        EditorSplitViewController(editor: editor)
    }

    func updateNSViewController(_ controller: EditorSplitViewController, context: Context) {
        controller.applyLayoutIfNeeded(editor.layoutPreset)
        controller.applyAgentVisibility(editor.agentPanelVisible)
        controller.applyMediaVisibility(editor.mediaPanelVisible)
        controller.applyInspectorVisibility(editor.inspectorPanelVisible)
        controller.applyMaximize(editor.maximizedPanel)
    }
}

// MARK: - Split view controller

final class EditorSplitViewController: NSSplitViewController {
    private let editor: EditorViewModel
    private var currentPreset: LayoutPreset?
    private var currentMaximized: EditorViewModel.FocusedPanel?
    private var pendingLayout: DispatchWorkItem?
    private weak var agentSplitItem: NSSplitViewItem?
    private weak var mediaSplitItem: NSSplitViewItem?
    private weak var previewSplitItem: NSSplitViewItem?
    private weak var inspectorSplitItem: NSSplitViewItem?
    private weak var timelineSplitItem: NSSplitViewItem?

    private lazy var mediaHC: NSViewController     = makeHosting(MediaPanelView(), panel: .media)
    private lazy var previewHC: NSViewController   = makeHosting(PreviewContainerView(), panel: .preview)
    private lazy var inspectorHC: NSViewController = makeHosting(InspectorView(), panel: .inspector)
    private lazy var agentHC: NSViewController     = makeHosting(AgentPanelView(), panel: .agent)
    private lazy var timelineHC: NSViewController  = makeHosting(
        VStack(spacing: 0) {
            ToolbarView().frame(height: Layout.toolbarHeight)
            TimelineContainerView()
        },
        panel: .timeline
    )

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thick
        buildLayout(editor.layoutPreset)
    }

    // MARK: - Layout switching

    func applyLayoutIfNeeded(_ preset: LayoutPreset) {
        guard preset != currentPreset else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, preset != self.currentPreset else { return }
            if self.currentMaximized != nil {
                self.currentMaximized = nil
                self.editor.maximizedPanel = nil
            }
            self.buildLayout(preset)
        }
    }

    func applyMaximize(_ panel: EditorViewModel.FocusedPanel?) {
        guard panel != currentMaximized else { return }
        currentMaximized = panel
        if let panel, let leaf = leafItem(for: panel) {
            for sibling in ancestorChainSiblings(of: leaf) {
                applyCollapsed(item: sibling, collapsed: true)
            }
        } else {
            walkSplitItems(self) { item in
                applyCollapsed(item: item, collapsed: self.restoredCollapseState(for: item))
            }
        }
    }

    private func leafItem(for panel: EditorViewModel.FocusedPanel) -> NSSplitViewItem? {
        switch panel {
        case .agent:     return agentSplitItem
        case .media:     return mediaSplitItem
        case .preview:   return previewSplitItem
        case .inspector: return inspectorSplitItem
        case .timeline:  return timelineSplitItem
        }
    }

    /// Walk up from a leaf split item, collecting siblings at every level up to the root.
    /// Those siblings are the items that must collapse for the leaf to fill the entire split.
    private func ancestorChainSiblings(of leaf: NSSplitViewItem) -> [NSSplitViewItem] {
        var result: [NSSplitViewItem] = []
        var current = leaf
        while let parent = current.viewController.parent as? NSSplitViewController {
            result.append(contentsOf: parent.splitViewItems.filter { $0 !== current })
            guard
                let grandparent = parent.parent as? NSSplitViewController,
                let wrapper = grandparent.splitViewItems.first(where: { $0.viewController === parent })
            else { break }
            current = wrapper
        }
        return result
    }

    private func walkSplitItems(_ controller: NSSplitViewController, _ visit: (NSSplitViewItem) -> Void) {
        for item in controller.splitViewItems {
            visit(item)
            if let child = item.viewController as? NSSplitViewController {
                walkSplitItems(child, visit)
            }
        }
    }

    /// On unmaximize, leaves restore their visibility-flag state
    private func restoredCollapseState(for item: NSSplitViewItem) -> Bool {
        if item === agentSplitItem     { return !editor.agentPanelVisible }
        if item === mediaSplitItem     { return !editor.mediaPanelVisible }
        if item === inspectorSplitItem { return !editor.inspectorPanelVisible }
        return false
    }

    func applyAgentVisibility(_ visible: Bool) {
        guard currentMaximized == nil else { return }
        applyCollapsed(item: agentSplitItem, collapsed: !visible)
    }

    func applyMediaVisibility(_ visible: Bool) {
        guard currentMaximized == nil else { return }
        applyCollapsed(item: mediaSplitItem, collapsed: !visible)
    }

    func applyInspectorVisibility(_ visible: Bool) {
        guard currentMaximized == nil else { return }
        applyCollapsed(item: inspectorSplitItem, collapsed: !visible)
    }

    private func applyCollapsed(item: NSSplitViewItem?, collapsed: Bool) {
        guard let item, item.isCollapsed != collapsed else { return }
        DispatchQueue.main.async {
            item.animator().isCollapsed = collapsed
        }
    }

    private func buildLayout(_ preset: LayoutPreset) {
        pendingLayout?.cancel()

        while !splitViewItems.isEmpty {
            removeSplitViewItem(splitViewItems.last!)
        }
        agentSplitItem = nil
        mediaSplitItem = nil
        previewSplitItem = nil
        inspectorSplitItem = nil
        timelineSplitItem = nil

        currentPreset = preset
        splitView.isVertical = true

        // Preset layout lives in an inner VC so the agent can be a sibling column.
        let presetRoot = makeChildSplit(isVertical: false)
        switch preset {
        case .default:  buildDefaultLayout(into: presetRoot)
        case .media:    buildMediaLayout(into: presetRoot)
        case .vertical: buildVerticalLayout(into: presetRoot)
        }

        let agentItem = NSSplitViewItem(viewController: agentHC)
        agentItem.canCollapse = false
        agentItem.isCollapsed = !editor.agentPanelVisible
        agentItem.minimumThickness = Layout.agentPanelMin
        addSplitViewItem(agentItem)
        agentSplitItem = agentItem

        let presetItem = NSSplitViewItem(viewController: presetRoot)
        presetItem.minimumThickness = 400
        addSplitViewItem(presetItem)
    }

    // MARK: - Default layout

    private func buildDefaultLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = false

        let hSplit = makeChildSplit(isVertical: true)
        hSplit.addSplitViewItem(makeMediaItem())
        hSplit.addSplitViewItem(makePreviewItem())
        hSplit.addSplitViewItem(makeInspectorItem())

        let upper = NSSplitViewItem(viewController: hSplit)
        upper.minimumThickness = Layout.previewMinHeight
        target.addSplitViewItem(upper)
        target.addSplitViewItem(makeTimelineItem())

        // Positions are set against each inner split's own bounds — not
        // self.view.bounds, which includes the agent column's width.
        applyAfterLayout { [weak target, weak hSplit] in
            guard let target, let hSplit else { return }
            let targetH = target.view.bounds.height
            let hW = hSplit.view.bounds.width
            target.splitView.setPosition(round(targetH * 0.7), ofDividerAt: 0)
            hSplit.splitView.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0)
            hSplit.splitView.setPosition(hW - Layout.inspectorDefault, ofDividerAt: 1)
        }
    }

    // MARK: - Media layout
    // [Media] | [Preview | Inspector] / [Toolbar + Timeline]

    private func buildMediaLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true)
        topSplit.addSplitViewItem(makePreviewItem())
        topSplit.addSplitViewItem(makeInspectorItem())

        let rightSplit = makeChildSplit(isVertical: false)
        let topItem = NSSplitViewItem(viewController: topSplit)
        topItem.minimumThickness = Layout.previewMinHeight
        rightSplit.addSplitViewItem(topItem)
        rightSplit.addSplitViewItem(makeTimelineItem())

        target.addSplitViewItem(makeMediaItem())
        target.addSplitViewItem(NSSplitViewItem(viewController: rightSplit))

        applyAfterLayout { [weak target, weak rightSplit, weak topSplit] in
            guard let target, let rightSplit, let topSplit else { return }
            let targetW = target.view.bounds.width
            let rightH = rightSplit.view.bounds.height
            let topW = topSplit.view.bounds.width
            let mediaWidth = round(targetW * 0.3)
            target.splitView.setPosition(mediaWidth, ofDividerAt: 0)
            rightSplit.splitView.setPosition(round(rightH * 0.55), ofDividerAt: 0)
            topSplit.splitView.setPosition(topW - Layout.inspectorDefault, ofDividerAt: 0)
        }
    }

    // MARK: - Vertical layout
    // [Media | Inspector] / [Toolbar + Timeline] | [Preview]

    private func buildVerticalLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true)
        topSplit.addSplitViewItem(makeMediaItem())
        topSplit.addSplitViewItem(makeInspectorItem())

        let leftSplit = makeChildSplit(isVertical: false)
        leftSplit.addSplitViewItem(NSSplitViewItem(viewController: topSplit))
        leftSplit.addSplitViewItem(makeTimelineItem())

        target.addSplitViewItem(NSSplitViewItem(viewController: leftSplit))
        target.addSplitViewItem(makePreviewItem())

        applyAfterLayout { [weak target, weak leftSplit, weak topSplit] in
            guard let target, let leftSplit, let topSplit else { return }
            let targetW = target.view.bounds.width
            let leftH = leftSplit.view.bounds.height
            target.splitView.setPosition(round(targetW * 0.5), ofDividerAt: 0)
            leftSplit.splitView.setPosition(round(leftH * 0.55), ofDividerAt: 0)
            topSplit.splitView.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0)
        }
    }

    // MARK: - Shared item builders

    private func makeChildSplit(isVertical: Bool) -> NSSplitViewController {
        let vc = NSSplitViewController()
        vc.splitView.isVertical = isVertical
        vc.splitView.dividerStyle = .thick
        return vc
    }

    private func makeMediaItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: mediaHC)
        item.minimumThickness = Layout.mediaPanelMin
        item.canCollapse = false
        item.isCollapsed = !editor.mediaPanelVisible
        mediaSplitItem = item
        return item
    }

    private func makePreviewItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: previewHC)
        item.minimumThickness = Layout.previewMinWidth
        previewSplitItem = item
        return item
    }

    private func makeInspectorItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: inspectorHC)
        item.minimumThickness = Layout.inspectorMin
        item.canCollapse = false
        item.isCollapsed = !editor.inspectorPanelVisible
        inspectorSplitItem = item
        return item
    }

    private func makeTimelineItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: timelineHC)
        item.minimumThickness = Layout.timelineMinHeight
        timelineSplitItem = item
        return item
    }

    private func makeHosting<V: View>(_ content: V, panel: EditorViewModel.FocusedPanel) -> NSHostingController<some View> {
        let hc = NSHostingController(
            rootView: content
                .environment(editor)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(AppTheme.Background.surfaceColor)
                .overlay {
                    PanelFocusRing(editor: editor, panel: panel)
                        .allowsHitTesting(false)
                }
        )
        hc.view.setAccessibilityIdentifier(panel.accessibilityID)
        return hc
    }

    private func applyAfterLayout(_ apply: @escaping () -> Void) {
        pendingLayout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            guard self.view.bounds.width > 0 else { return }
            apply()
            self.mediaSplitItem?.isCollapsed = !self.editor.mediaPanelVisible
            self.inspectorSplitItem?.isCollapsed = !self.editor.inspectorPanelVisible
        }
        pendingLayout = work
        DispatchQueue.main.async(execute: work)
    }
}

// MARK: - Panel focus ring overlay

private struct PanelFocusRing: View {
    var editor: EditorViewModel
    let panel: EditorViewModel.FocusedPanel

    private var isFocused: Bool { editor.focusedPanel == panel }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(Color.accentColor, lineWidth: isFocused ? 1.5 : 0)
            .opacity(isFocused ? 0.6 : 0)
            .animation(.easeOut(duration: AppTheme.Anim.transition), value: isFocused)
    }
}
