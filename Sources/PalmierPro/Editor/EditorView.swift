import AppKit
import SwiftUI

struct EditorView: NSViewControllerRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSViewController(context: Context) -> EditorSplitViewController {
        EditorSplitViewController(editor: editor)
    }

    func updateNSViewController(_ controller: EditorSplitViewController, context: Context) {}
}

// MARK: - Split view controller

final class EditorSplitViewController: NSSplitViewController {
    private let editor: EditorViewModel
    private weak var horizontalSplit: NSSplitViewController?

    init(editor: EditorViewModel) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = false
        splitView.dividerStyle = .thin

        // Top: horizontal split (media | preview | inspector)
        let hSplit = NSSplitViewController()
        hSplit.splitView.isVertical = true
        hSplit.splitView.dividerStyle = .thin
        horizontalSplit = hSplit

        let mediaItem = NSSplitViewItem(viewController: makeHosting(
            MediaPanelView().accessibilityIdentifier("mediaPanel")
        ))
        mediaItem.minimumThickness = Layout.mediaPanelMin
        mediaItem.maximumThickness = Layout.mediaPanelMax
        mediaItem.canCollapse = false

        let previewItem = NSSplitViewItem(viewController: makeHosting(
            PreviewContainerView()
        ))
        previewItem.minimumThickness = Layout.previewMinWidth

        let inspectorItem = NSSplitViewItem(viewController: makeHosting(
            InspectorView()
        ))
        inspectorItem.minimumThickness = Layout.inspectorMin
        inspectorItem.maximumThickness = Layout.inspectorMax
        inspectorItem.canCollapse = false

        hSplit.addSplitViewItem(mediaItem)
        hSplit.addSplitViewItem(previewItem)
        hSplit.addSplitViewItem(inspectorItem)

        // Bottom: toolbar + timeline
        let topItem = NSSplitViewItem(viewController: hSplit)

        let bottomItem = NSSplitViewItem(viewController: makeHosting(
            VStack(spacing: 0) {
                ToolbarView()
                    .frame(height: Layout.toolbarHeight)
                TimelineContainerView()
            }
        ))
        bottomItem.minimumThickness = Layout.timelineMinHeight

        addSplitViewItem(topItem)
        addSplitViewItem(bottomItem)
    }

    // MARK: - Default divider positions

    private var defaultsApplied = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !defaultsApplied else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        defaultsApplied = true

        splitView.setPosition(round(size.height * 0.55), ofDividerAt: 0)
        horizontalSplit?.splitView.setPosition(Layout.mediaPanelDefault, ofDividerAt: 0)
        horizontalSplit?.splitView.setPosition(size.width - Layout.inspectorDefault, ofDividerAt: 1)
    }

    private func makeHosting<V: View>(_ content: V) -> NSHostingController<some View> {
        NSHostingController(
            rootView: content
                .environment(editor)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        )
    }
}
