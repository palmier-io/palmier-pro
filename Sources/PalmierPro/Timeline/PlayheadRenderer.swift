import AppKit

enum PlayheadRenderer {

    /// Draws the playhead: red vertical line across all tracks + triangle on ruler.
    static func draw(
        frame: Int,
        pixelsPerFrame: Double,
        scrollOffsetX: CGFloat,
        headerWidth: CGFloat,
        rulerHeight: CGFloat,
        totalHeight: CGFloat,
        context: CGContext
    ) {
        let x = headerWidth + Double(frame) * pixelsPerFrame - Double(scrollOffsetX)
        let color = NSColor.systemRed.cgColor

        // Vertical line
        context.setStrokeColor(color)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: x, y: Double(rulerHeight)))
        context.addLine(to: CGPoint(x: x, y: Double(totalHeight)))
        context.strokePath()

        // Triangle head on ruler
        let triSize: Double = 8
        context.setFillColor(color)
        context.move(to: CGPoint(x: x, y: Double(rulerHeight)))
        context.addLine(to: CGPoint(x: x - triSize / 2, y: Double(rulerHeight) - triSize))
        context.addLine(to: CGPoint(x: x + triSize / 2, y: Double(rulerHeight) - triSize))
        context.closePath()
        context.fillPath()
    }
}
