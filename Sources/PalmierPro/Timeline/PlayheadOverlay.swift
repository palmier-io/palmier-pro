import AppKit

/// Playhead CAShapeLayer driven by `withObservationTracking`
@MainActor
final class PlayheadOverlay {
    private let layer = CAShapeLayer()
    private weak var view: TimelineView?
    private weak var editor: EditorViewModel?

    init(view: TimelineView, editor: EditorViewModel) {
        self.view = view
        self.editor = editor
        let red = NSColor.systemRed.cgColor
        layer.fillColor = red
        layer.strokeColor = red
        layer.lineWidth = 1
        layer.zPosition = 100
        view.layer?.addSublayer(layer)
        observe()
    }

    /// Idempotent — safe to call alongside the async observation fire.
    func update() {
        guard let view, let editor else { return }
        let geo = view.geometry
        let scrollOffset = view.enclosingScrollView?.contentView.bounds.origin ?? .zero
        let visibleHeight = view.enclosingScrollView?.contentView.bounds.height ?? view.bounds.height
        let x = Double(editor.currentFrame) * geo.pixelsPerFrame
        let top = scrollOffset.y + Double(geo.rulerHeight)
        let bottom = scrollOffset.y + Double(visibleHeight)
        let triSize: CGFloat = 8
        let halfTri = triSize / 2

        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: bottom))
        // Triangle is a separate closed subpath so fill applies to it but not the line.
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x - halfTri, y: top - triSize))
        path.addLine(to: CGPoint(x: x + halfTri, y: top - triSize))
        path.closeSubpath()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.frame != view.bounds {
            layer.frame = view.bounds
        }
        layer.path = path
        CATransaction.commit()
    }

    /// Single-shot — re-arms after each fire. Task hop reads the post-set value
    /// (onChange runs during willSet).
    private func observe() {
        withObservationTracking {
            _ = editor?.currentFrame
            _ = editor?.zoomScale
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observe()
            }
        }
    }
}
