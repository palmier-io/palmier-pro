import AppKit
import SwiftUI

struct MediaPanelDropArea<Content: View>: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: (_ urls: [URL]) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> DropHostingView<Content> {
        let view = DropHostingView(rootView: content())
        view.onTargetChanged = { isTargeted = $0 }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: DropHostingView<Content>, context: Context) {
        nsView.rootView = content()
        nsView.onTargetChanged = { isTargeted = $0 }
        nsView.onDrop = onDrop
    }
}

final class DropHostingView<Content: View>: NSHostingView<Content> {
    var onTargetChanged: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onTargetChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        let urls: [URL] = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
