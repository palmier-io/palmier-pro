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
    }
}

// MARK: - Split view controller

final class EditorSplitViewController: NSSplitViewController {
    private let editor: EditorViewModel
    private var currentPreset: LayoutPreset?
    private var pendingLayout: DispatchWorkItem?
    private weak var agentSplitItem: NSSplitViewItem?
    private weak var mediaSplitItem: NSSplitViewItem?
    private weak var inspectorSplitItem: NSSplitViewItem?

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
        splitView.dividerStyle = .thin
        buildLayout(editor.layoutPreset)
    }

    // MARK: - Layout switching

    func applyLayoutIfNeeded(_ preset: LayoutPreset) {
        guard preset != currentPreset else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, preset != self.currentPreset else { return }
            self.buildLayout(preset)
        }
    }

    func applyAgentVisibility(_ visible: Bool) {
        applyVisibility(item: agentSplitItem, visible: visible)
    }

    func applyMediaVisibility(_ visible: Bool) {
        applyVisibility(item: mediaSplitItem, visible: visible)
    }

    func applyInspectorVisibility(_ visible: Bool) {
        applyVisibility(item: inspectorSplitItem, visible: visible)
    }

    private func applyVisibility(item: NSSplitViewItem?, visible: Bool) {
        guard let item else { return }
        let targetCollapsed = !visible
        guard item.isCollapsed != targetCollapsed else { return }
        DispatchQueue.main.async {
            item.animator().isCollapsed = targetCollapsed
        }
    }

    private func buildLayout(_ preset: LayoutPreset) {
        pendingLayout?.cancel()

        while !splitViewItems.isEmpty {
            removeSplitViewItem(splitViewItems.last!)
        }
        agentSplitItem = nil
        mediaSplitItem = nil
        inspectorSplitItem = nil

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
        agentItem.canCollapse = true
        agentItem.isCollapsed = !editor.agentPanelVisible
        agentItem.minimumThickness = Layout.agentPanelMin
        agentItem.maximumThickness = Layout.agentPanelMax
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

        target.addSplitViewItem(NSSplitViewItem(viewController: hSplit))
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
        rightSplit.addSplitViewItem(NSSplitViewItem(viewController: topSplit))
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
        vc.splitView.dividerStyle = .thin
        return vc
    }

    private func makeMediaItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: mediaHC)
        item.minimumThickness = Layout.mediaPanelMin
        item.maximumThickness = Layout.mediaPanelMax
        item.canCollapse = true
        item.isCollapsed = !editor.mediaPanelVisible
        mediaSplitItem = item
        return item
    }

    private func makePreviewItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: previewHC)
        item.minimumThickness = Layout.previewMinWidth
        item.maximumThickness = Layout.previewMaxWidth
        return item
    }

    private func makeInspectorItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: inspectorHC)
        item.minimumThickness = Layout.inspectorMin
        item.maximumThickness = Layout.inspectorMax
        item.canCollapse = true
        item.isCollapsed = !editor.inspectorPanelVisible
        inspectorSplitItem = item
        return item
    }

    private func makeTimelineItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(viewController: timelineHC)
        item.minimumThickness = Layout.timelineMinHeight
        item.maximumThickness = Layout.timelineMaxHeight
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
