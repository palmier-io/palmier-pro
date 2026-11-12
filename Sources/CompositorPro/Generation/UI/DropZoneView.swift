import AppKit
import SwiftUI

/// Transparent native AppKit drop target.
struct DropTargetOverlay: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var onDrop: (String) -> Void

    func makeNSView(context: Context) -> DropTargetNSView {
        let view = DropTargetNSView()
        view.onTargetChanged = { isTargeted = $0 }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: DropTargetNSView, context: Context) {
        nsView.onTargetChanged = { isTargeted = $0 }
        nsView.onDrop = onDrop
    }
}

final class DropTargetNSView: NSView {
    var onTargetChanged: ((Bool) -> Void)?
    var onDrop: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { fatalError() }

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
        guard let payload = sender.draggingPasteboard.string(forType: .string) else {
            Log.generation.notice("drop perform: no string payload")
            return false
        }
        Log.generation.notice("drop perform payloadLen=\(payload.count) tail=\(payload.suffix(60))")
        onDrop?(payload)
        return true
    }
}
