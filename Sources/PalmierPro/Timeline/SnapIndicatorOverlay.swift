import AppKit

/// Dashed yellow snap-line CAShapeLayer. Two X sources (local drag, external drop) —
@MainActor
final class SnapIndicatorOverlay {
    private let layer = CAShapeLayer()
    private weak var view: TimelineView?

    private var localX: Double?
    private var externalX: Double?

    init(view: TimelineView) {
        self.view = view
        layer.strokeColor = NSColor.systemYellow.cgColor
        layer.fillColor = nil
        layer.lineWidth = 1
        layer.lineDashPattern = [4, 4]
        layer.zPosition = 90
        layer.isHidden = true
        view.layer?.addSublayer(layer)
    }

    func setLocalX(_ x: Double?) {
        guard localX != x else { return }
        localX = x
        update()
    }

    func setExternalX(_ x: Double?) {
        guard externalX != x else { return }
        externalX = x
        update()
    }

    private func update() {
        guard let view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let x = localX ?? externalX {
            let geo = view.geometry
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: Double(geo.rulerHeight)))
            path.addLine(to: CGPoint(x: x, y: Double(view.bounds.height)))
            layer.path = path
            if layer.frame != view.bounds {
                layer.frame = view.bounds
            }
            layer.isHidden = false
        } else {
            layer.isHidden = true
            layer.path = nil
        }
        CATransaction.commit()
    }
}
