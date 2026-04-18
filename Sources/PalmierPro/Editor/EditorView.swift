import AppKit
import SwiftUI

struct EditorView: NSViewControllerRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSViewController(context: Context) -> EditorSplitViewController {
        EditorSplitViewController(editor: editor)
    }

    func updateNSViewController(_ controller: EditorSplitViewController, context: Context) {
        controller.applyLayoutIfNeeded(editor.layoutPreset)
    }
}

// MARK: - Split view controller

final class EditorSplitViewController: NSSplitViewController {
    private let editor: EditorViewModel
    private var currentPreset: LayoutPreset?
    private var pendingLayout: DispatchWorkItem?

    private lazy var mediaHC: NSViewController     = makeHosting(MediaPanelView(), panel: .media)
    private lazy var previewHC: NSViewController   = makeHosting(PreviewContainerView(), panel: .preview)
    private lazy var inspectorHC: NSViewController = makeHosting(InspectorView(), panel: .inspector)
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

    private func buildLayout(_ preset: LayoutPreset) {
        pendingLayout?.cancel()

        while !splitViewItems.isEmpty {
            removeSplitViewItem(splitViewItems.last!)
        }

        currentPreset = preset

        switch preset {
        case .default: buildDefaultLayout()
        case .media:   buildMediaLayout()
        case .vertical: buildVerticalLayout()
        }
    }

    // MARK: - Default layout

    private func buildDefaultLayout() {
        splitView.isVertical = false

        let hSplit = makeChildSplit(isVertical: true)
        hSplit.addSplitViewItem(makeMediaItem())
        hSplit.addSplitViewItem(makePreviewItem())
        hSplit.addSplitViewItem(makeInspectorItem())

        addSplitViewItem(NSSplitViewItem(viewController: hSplit))
        addSplitViewItem(makeTimelineItem())

        scheduleDividerPositions { size in
            self.splitView.setPosition(round(size.height * 0.55), ofDividerAt: 0)
            hSplit.splitView.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0)
            hSplit.splitView.setPosition(size.width - Layout.inspectorDefault, ofDividerAt: 1)
        }
    }

    // MARK: - Media layout
    // [Media] | [Preview | Inspector] / [Toolbar + Timeline]

    private func buildMediaLayout() {
        splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true)
        topSplit.addSplitViewItem(makePreviewItem())
        topSplit.addSplitViewItem(makeInspectorItem())

        let rightSplit = makeChildSplit(isVertical: false)
        rightSplit.addSplitViewItem(NSSplitViewItem(viewController: topSplit))
        rightSplit.addSplitViewItem(makeTimelineItem())

        addSplitViewItem(makeMediaItem())
        addSplitViewItem(NSSplitViewItem(viewController: rightSplit))

        scheduleDividerPositions { size in
            let mediaWidth = round(size.width * 0.3)
            self.splitView.setPosition(mediaWidth, ofDividerAt: 0)
            rightSplit.splitView.setPosition(round(size.height * 0.55), ofDividerAt: 0)
            topSplit.splitView.setPosition(size.width - mediaWidth - Layout.inspectorDefault, ofDividerAt: 0)
        }
    }

    // MARK: - Vertical layout
    // [Media | Inspector] / [Toolbar + Timeline] | [Preview]

    private func buildVerticalLayout() {
        splitView.isVertical = true

        let topSplit = makeChildSplit(isVertical: true)
        topSplit.addSplitViewItem(makeMediaItem())
        topSplit.addSplitViewItem(makeInspectorItem())

        let leftSplit = makeChildSplit(isVertical: false)
        leftSplit.addSplitViewItem(NSSplitViewItem(viewController: topSplit))
        leftSplit.addSplitViewItem(makeTimelineItem())

        addSplitViewItem(NSSplitViewItem(viewController: leftSplit))
        addSplitViewItem(makePreviewItem())

        scheduleDividerPositions { size in
            self.splitView.setPosition(round(size.width * 0.5), ofDividerAt: 0)
            leftSplit.splitView.setPosition(round(size.height * 0.55), ofDividerAt: 0)
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
        item.canCollapse = false
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
        item.canCollapse = false
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

    private func scheduleDividerPositions(_ apply: @escaping (CGSize) -> Void) {
        pendingLayout?.cancel()
        view.layoutSubtreeIfNeeded()
        if view.bounds.size.width > 0 {
            apply(view.bounds.size)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.view.bounds.size.width > 0 else { return }
            apply(self.view.bounds.size)
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
