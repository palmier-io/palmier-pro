import AppKit

enum PlayheadRenderer {

    /// Draws the playhead: red vertical line across all tracks + triangle on ruler.
    static func draw(
        frame: Int,
        pixelsPerFrame: Double,
        rulerHeight: CGFloat,
        scrollOffsetY: CGFloat,
        visibleHeight: CGFloat,
        context: CGContext
    ) {
        let x = Double(frame) * pixelsPerFrame
        let color = NSColor.systemRed.cgColor
        let top = scrollOffsetY + rulerHeight
        let bottom = scrollOffsetY + visibleHeight

        // Vertical line
        context.setStrokeColor(color)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: x, y: top))
        context.addLine(to: CGPoint(x: x, y: bottom))
        context.strokePath()

        // Triangle head on ruler
        let triSize: Double = 8
        context.setFillColor(color)
        context.move(to: CGPoint(x: x, y: top))
        context.addLine(to: CGPoint(x: x - triSize / 2, y: top - triSize))
        context.addLine(to: CGPoint(x: x + triSize / 2, y: top - triSize))
        context.closePath()
        context.fillPath()
    }
}
