import AppKit

enum ClipRenderer {

    static func draw(
        _ clip: Clip,
        type: ClipType,
        in rect: NSRect,
        isSelected: Bool,
        opacity: CGFloat = 1.0,
        context: CGContext
    ) {
        if opacity < 1.0 {
            context.saveGState()
            context.setAlpha(opacity)
        }

        let cornerRadius = Trim.clipCornerRadius
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Fill
        let fill = isSelected ? AppTheme.ClipFill.selected : AppTheme.ClipFill.base
        context.setFillColor(fill.cgColor)
        context.addPath(path)
        context.fillPath()

        // Color-coded left edge strip
        let stripWidth: CGFloat = 3
        let stripRect = NSRect(x: rect.minX, y: rect.minY, width: stripWidth, height: rect.height)
        let stripPath = CGPath(roundedRect: stripRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.setFillColor(type.themeColor.cgColor)
        context.addPath(stripPath)
        context.fillPath()

        // Border
        let borderColor = isSelected
            ? type.themeColor.withAlphaComponent(0.6).cgColor
            : AppTheme.Border.primary.cgColor
        context.setStrokeColor(borderColor)
        context.setLineWidth(isSelected ? 1 : 0.5)
        context.addPath(path)
        context.strokePath()

        // Label
        drawLabel(clip.mediaRef, in: rect, context: context)

        // Trim handles
        drawTrimHandles(in: rect, context: context)

        if opacity < 1.0 {
            context.restoreGState()
        }
    }

    // MARK: - Label

    private static func drawLabel(_ text: String, in rect: NSRect, context: CGContext) {
        guard rect.width > 30 else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: AppTheme.FontSize.xs, weight: .medium),
            .foregroundColor: AppTheme.Text.primary,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let inset: CGFloat = 8 // extra inset to clear the edge strip
        let origin = NSPoint(
            x: rect.minX + inset,
            y: rect.midY - size.height / 2
        )
        context.saveGState()
        context.clip(to: rect.insetBy(dx: inset, dy: 2))
        str.draw(at: origin)
        context.restoreGState()
    }

    // MARK: - Trim handles

    private static func drawTrimHandles(in rect: NSRect, context: CGContext) {
        let w = Trim.handleWidth
        context.setFillColor(AppTheme.Text.muted.cgColor)
        // Left handle
        context.fill(NSRect(x: rect.minX, y: rect.minY, width: w, height: rect.height))
        // Right handle
        context.fill(NSRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height))
    }
}
