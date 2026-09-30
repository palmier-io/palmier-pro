import AppKit
import SwiftUI

struct EditorView: NSViewControllerRepresentable {
    @Environment(EditorViewModel.self) var editor
    @Bindable private var workspaceLayout = WorkspaceLayoutStore.shared

    func makeNSViewController(context: Context) -> EditorSplitViewController {
        EditorSplitViewController(editor: editor)
    }

    func updateNSViewController(_ controller: EditorSplitViewController, context: Context) {
        controller.applyLayoutIfNeeded(workspaceLayout.selection)
        controller.applyAgentVisibility(editor.agentPanelVisible)
        controller.applyMediaVisibility(editor.mediaPanelVisible)
        controller.applyInspectorVisibility(editor.inspectorPanelVisible)
        controller.applyMaximize(editor.maximizedPanel)
        controller.updateTourFrame(stepIndex: editor.tour.stepIndex, anchorRevision: editor.tour.anchorRevision)
    }
}

// MARK: - Split view controller

private final class PanelDividerSplitView: NSSplitView {
    var showsDivider = true

    override var dividerThickness: CGFloat {
        showsDivider ? AppTheme.BorderWidth.thin : AppTheme.Spacing.zero
    }

    override func drawDivider(in rect: NSRect) {
        guard showsDivider else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            AppTheme.Border.panel.setFill()
            rect.fill()
        }
    }
}

/// Visible divider with a larger hit area for panel resizing.
class PaddedDividerSplitViewController: NSSplitViewController {
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        splitView = PanelDividerSplitView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        splitView = PanelDividerSplitView()
    }

    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let pad = Layout.panelGap / 2
        return splitView.isVertical
            ? drawnRect.insetBy(dx: -pad, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -pad)
    }
}

/// Autosave keys for the editor splits, defined once so call sites can't drift.
private enum SplitAutosave {
    static let root         = "editor.root"
    static let defaultH     = "editor.default.h"
    static let mediaTop     = "editor.media.top"
    static let mediaRight   = "editor.media.right"
    static let verticalTop  = "editor.vertical.top"
    static let verticalLeft = "editor.vertical.left"
    static func preset(_ p: LayoutPreset) -> String { "editor.\(p.rawValue).preset" }

    /// AppKit persists divider frames under this key; no public API queries it.
    static func hasSavedFrames(_ name: String?) -> Bool {
        guard let name else { return false }
        return UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(name)") != nil
    }
}

final class EditorSplitViewController: PaddedDividerSplitViewController {
    let editor: EditorViewModel
    private var currentPreset: LayoutPreset?
    private var currentMaximized: EditorViewModel.FocusedPanel?
    private var pendingPositioning: (() -> Void)?
    private weak var agentSplitItem: NSSplitViewItem?
    private weak var mediaSplitItem: NSSplitViewItem?
    private weak var previewSplitItem: NSSplitViewItem?
    private weak var inspectorSplitItem: NSSplitViewItem?
    private weak var timelineSplitItem: NSSplitViewItem?

    private let editorTitlebarFill = EditorTitlebarFillView()
    private lazy var mediaHC: NSViewController     = makeHosting(MediaPanelView(), panel: .media)
    private lazy var previewHC: NSViewController   = makeHosting(PreviewContainerView(), panel: .preview)
    private lazy var inspectorHC: NSViewController = makeHosting(InspectorView(), panel: .inspector)
    private lazy var agentHC: NSViewController     = makeAgentSidebarHosting(AgentPanelView())
    private lazy var timelineHC: NSViewController  = makeHosting(TimelinePaneView(), panel: .timeline)

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
        (splitView as? PanelDividerSplitView)?.showsDivider = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        splitView.autosaveName = SplitAutosave.root
        buildLayout(WorkspaceLayoutStore.shared.selection)
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

    func leafItem(for panel: EditorViewModel.FocusedPanel) -> NSSplitViewItem? {
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
        pendingPositioning = nil

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
        let presetRoot = makeChildSplit(isVertical: false, autosave: SplitAutosave.preset(preset))
        installEditorTitlebarFill(in: presetRoot.view)
        switch preset {
        case .default:  buildDefaultLayout(into: presetRoot)
        case .media:    buildMediaLayout(into: presetRoot)
        case .vertical: buildVerticalLayout(into: presetRoot)
        }

        let agentItem = NSSplitViewItem(viewController: agentHC)
        agentItem.canCollapse = false
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

        let hSplit = makeChildSplit(isVertical: true, autosave: SplitAutosave.defaultH)
        hSplit.addSplitViewItem(makeMediaItem())
        hSplit.addSplitViewItem(makePreviewItem())
        hSplit.addSplitViewItem(makeInspectorItem())

        let upper = NSSplitViewItem(viewController: hSplit)
        upper.minimumThickness = Layout.previewMinHeight
        target.addSplitViewItem(upper)
        target.addSplitViewItem(makeTimelineItem())

        // Positions are set against each inner split's own bounds — not
        // self.view.bounds, which includes the agent column's width.
        applyAfterLayout { [weak self, weak target, weak hSplit] in
            guard let self, let target, let hSplit else { return }
            let targetH = target.view.bounds.height
            let hW = hSplit.view.bounds.width
            self.positionIfUnsaved(target) { $0.setPosition(round(targetH * (1 - Layout.timelineDefaultHeightFraction)), ofDividerAt: 0) }
            self.positionIfUnsaved(hSplit) {
                $0.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0)
                $0.setPosition(hW - Layout.inspectorDefault, ofDividerAt: 1)
            }
        }
    }

    // MARK: - Media layout
    // [Media] | [Preview | Inspector] / [Toolbar + Timeline]

    private func buildMediaLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true, autosave: SplitAutosave.mediaTop)
        topSplit.addSplitViewItem(makePreviewItem())
        topSplit.addSplitViewItem(makeInspectorItem())

        let rightSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.mediaRight)
        let topItem = NSSplitViewItem(viewController: topSplit)
        topItem.minimumThickness = Layout.previewMinHeight
        rightSplit.addSplitViewItem(topItem)
        rightSplit.addSplitViewItem(makeTimelineItem())

        target.addSplitViewItem(makeMediaItem())
        target.addSplitViewItem(NSSplitViewItem(viewController: rightSplit))

        applyAfterLayout { [weak self, weak target, weak rightSplit, weak topSplit] in
            guard let self, let target, let rightSplit, let topSplit else { return }
            let targetW = target.view.bounds.width
            let rightH = rightSplit.view.bounds.height
            let topW = topSplit.view.bounds.width
            self.positionIfUnsaved(target) { $0.setPosition(round(targetW * 0.3), ofDividerAt: 0) }
            self.positionIfUnsaved(rightSplit) { $0.setPosition(round(rightH * 0.55), ofDividerAt: 0) }
            self.positionIfUnsaved(topSplit) { $0.setPosition(topW - Layout.inspectorDefault, ofDividerAt: 0) }
        }
    }

    // MARK: - Vertical layout
    // [Media | Inspector] / [Toolbar + Timeline] | [Preview]

    private func buildVerticalLayout(into target: NSSplitViewController) {
        target.splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true, autosave: SplitAutosave.verticalTop)
        topSplit.addSplitViewItem(makeMediaItem())
        topSplit.addSplitViewItem(makeInspectorItem())

        let leftSplit = makeChildSplit(isVertical: false, autosave: SplitAutosave.verticalLeft)
        leftSplit.addSplitViewItem(NSSplitViewItem(viewController: topSplit))
        leftSplit.addSplitViewItem(makeTimelineItem())

        target.addSplitViewItem(NSSplitViewItem(viewController: leftSplit))
        target.addSplitViewItem(makePreviewItem())

        applyAfterLayout { [weak self, weak target, weak leftSplit, weak topSplit] in
            guard let self, let target, let leftSplit, let topSplit else { return }
            let targetW = target.view.bounds.width
            let leftH = leftSplit.view.bounds.height
            self.positionIfUnsaved(target) { $0.setPosition(round(targetW * 0.5), ofDividerAt: 0) }
            self.positionIfUnsaved(leftSplit) { $0.setPosition(round(leftH * 0.55), ofDividerAt: 0) }
            self.positionIfUnsaved(topSplit) { $0.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0) }
        }
    }

    // MARK: - Shared item builders

    private func makeChildSplit(isVertical: Bool, autosave: String? = nil) -> NSSplitViewController {
        let vc = PaddedDividerSplitViewController()
        vc.splitView.isVertical = isVertical
        vc.splitView.dividerStyle = .thin
        vc.splitView.autosaveName = autosave
        return vc
    }

    /// Default positions apply per split: each is skipped independently once it has autosaved frames.
    private func positionIfUnsaved(_ controller: NSSplitViewController, _ apply: (NSSplitView) -> Void) {
        guard !SplitAutosave.hasSavedFrames(controller.splitView.autosaveName) else { return }
        apply(controller.splitView)
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
                .appLocalization()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background {
                    AppTheme.Background.surfaceColor
                        .ignoresSafeArea(edges: .top)
                }
                .overlay {
                    PanelFocusRing(panel: panel)
                        .allowsHitTesting(false)
                }
        )
        hc.sizingOptions = []
        hc.view.setAccessibilityIdentifier(panel.accessibilityID)
        return hc
    }

    private func makeAgentSidebarHosting<V: View>(_ content: V) -> NSHostingController<some View> {
        let hc = NSHostingController(
            rootView: content
                .environment(editor)
                .appLocalization()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        )
        hc.sizingOptions = []
        hc.view.setAccessibilityIdentifier(EditorViewModel.FocusedPanel.agent.accessibilityID)
        return hc
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if pendingPositioning != nil {
            DispatchQueue.main.async { [weak self] in self?.runPendingPositioning() }
        }
        updateTourFrame()   // see EditorSplitViewController+Tour.swift
        updateEditorTitlebarFill()
    }

    private func installEditorTitlebarFill(in editorColumn: NSView) {
        if editorTitlebarFill.superview !== editorColumn {
            editorTitlebarFill.removeFromSuperview()
            editorColumn.addSubview(editorTitlebarFill, positioned: .above, relativeTo: nil)
            editorTitlebarFill.autoresizingMask = [.width, .minYMargin]
        }
        updateEditorTitlebarFill()
    }

    private func updateEditorTitlebarFill() {
        guard let editorColumn = editorTitlebarFill.superview else { return }
        let height = titlebarOverlapHeight(in: editorColumn)
        editorTitlebarFill.frame = NSRect(
            x: 0,
            y: editorColumn.bounds.height - height,
            width: editorColumn.bounds.width,
            height: height
        )
    }

    private func titlebarOverlapHeight(in editorColumn: NSView) -> CGFloat {
        if editorColumn.safeAreaInsets.top > 0 { return editorColumn.safeAreaInsets.top }
        guard let content = editorColumn.window?.contentView else { return 0 }
        let column = editorColumn.convert(editorColumn.bounds, to: content)
        let titlebarMinY = content.bounds.maxY - content.safeAreaInsets.top
        return max(0, column.maxY - titlebarMinY)
    }

    private func applyAfterLayout(_ apply: @escaping () -> Void) {
        pendingPositioning = { [weak self] in
            guard let self else { return }
            apply()
            self.mediaSplitItem?.isCollapsed = !self.editor.mediaPanelVisible
            self.inspectorSplitItem?.isCollapsed = !self.editor.inspectorPanelVisible
        }
        view.needsLayout = true
    }

    private func runPendingPositioning() {
        guard view.bounds.width > 0, let work = pendingPositioning else { return }
        pendingPositioning = nil
        work()
        updateTourFrame()
        updateEditorTitlebarFill()
    }
}

private struct PanelFocusRing: View {
    @Environment(EditorViewModel.self) var editor
    let panel: EditorViewModel.FocusedPanel

    private var isFocused: Bool { editor.focusedPanel == panel }

    var body: some View {
        Rectangle()
            .strokeBorder(AppTheme.Accent.primary, lineWidth: AppTheme.BorderWidth.thin)
            .opacity(isFocused ? AppTheme.Opacity.strong : 0)
            .animation(.easeOut(duration: AppTheme.Anim.transition), value: isFocused)
    }
}

/// Window chrome in the titlebar band of the editor column. Width tracks the column.
private final class EditorTitlebarFillView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            AppTheme.Background.base.setFill()
            bounds.fill()
            AppTheme.Border.panel.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: AppTheme.BorderWidth.thin).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
