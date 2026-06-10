import AppKit

enum Playhead {
    static let color: NSColor = .systemRed
    static let triangleSize: CGFloat = 8

    static func appendPath(
        _ path: CGMutablePath,
        x: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        triangle: Bool
    ) {
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: bottom))
        if triangle {
            let half = triangleSize / 2
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x - half, y: top - triangleSize))
            path.addLine(to: CGPoint(x: x + half, y: top - triangleSize))
            path.closeSubpath()
        }
    }
}

/// Playhead CAShapeLayer driven by `withObservationTracking`
@MainActor
final class PlayheadOverlay {
    private let layer = CAShapeLayer()
    private weak var view: TimelineView?
    private weak var editor: EditorViewModel?

    init(view: TimelineView, editor: EditorViewModel) {
        self.view = view
        self.editor = editor
        let cg = Playhead.color.cgColor
        layer.fillColor = cg
        layer.strokeColor = cg
        layer.lineWidth = 1
        layer.zPosition = 100
        view.layer?.addSublayer(layer)
        observe()
    }

    /// Idempotent — safe to call alongside the async observation fire.
    func update() {
        guard let view, let editor else { return }
        let geo = view.geometry
        let viewport = view.visibleRect
        guard !viewport.isEmpty else { return }
        let x = Double(editor.playheadState.timelineFrame) * geo.pixelsPerFrame - viewport.minX
        let top = Double(geo.rulerHeight)
        let bottom = Double(viewport.height)

        let path = CGMutablePath()
        Playhead.appendPath(path, x: x, top: top, bottom: bottom, triangle: true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.frame != viewport {
            layer.frame = viewport
        }
        layer.path = path
        CATransaction.commit()
    }

    /// Re-arms after each fire; the Task hop reads the post-set value.
    private func observe() {
        withObservationTracking {
            _ = editor?.playheadState.timelineFrame
            _ = editor?.zoomScale
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observe()
            }
        }
    }
}
