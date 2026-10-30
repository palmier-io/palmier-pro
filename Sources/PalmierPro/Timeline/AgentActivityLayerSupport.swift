import AppKit

enum AgentActivityLayerSupport {
    static func updateMask(
        _ layer: CALayer,
        bounds: CGRect,
        rulerHeight: CGFloat
    ) {
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.fillColor = AppTheme.MediaOverlay.background.cgColor
        mask.path = CGPath(
            rect: CGRect(
                x: 0,
                y: rulerHeight,
                width: bounds.width,
                height: max(0, bounds.height - rulerHeight)
            ),
            transform: nil
        )
        layer.mask = mask
    }

    static func updateAnimation(
        _ layer: CALayer,
        hasHighlight: Bool,
        staysVisible: Bool,
        hold: Double,
        duration: Double
    ) {
        layer.removeAnimation(forKey: "agentActivityFade")
        guard hasHighlight else {
            layer.opacity = 0
            return
        }
        guard !staysVisible else {
            layer.opacity = 1
            return
        }

        layer.opacity = 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 1, 0]
        animation.keyTimes = [0, NSNumber(value: hold / duration), 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut),
        ]
        animation.duration = duration
        layer.add(animation, forKey: "agentActivityFade")
    }
}
