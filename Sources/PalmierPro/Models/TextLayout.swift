import AppKit

/// Natural bounding size of a rendered text clip, shared between the layer
/// controller and clip placement.
enum TextLayout {
    static let shadowPadding: CGFloat = 12
    static let referenceCanvasHeight: CGFloat = 1080

    static func naturalSize(
        content: String,
        style: TextStyle,
        maxWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> CGSize {
        let displayText = style.displayText(content)
        let measured = displayText.isEmpty ? " " : displayText
        let canvasScale = canvasHeight / referenceCanvasHeight
        let renderSize = CGFloat(style.fontSize * style.fontScale) * canvasScale
        let str = NSAttributedString(
            string: measured,
            attributes: style.attributes(size: renderSize, includeColor: false)
        )
        let bounding = str.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // +4px slack absorbs canvas→preview scale rounding.
        let slack: CGFloat = 4
        let shadowBlur = max(0, CGFloat(style.shadow.blur))
        let shadowX = style.shadow.enabled
            ? max(shadowPadding, shadowBlur + abs(CGFloat(style.shadow.offsetX))) * canvasScale * 2
            : 0
        let shadowY = style.shadow.enabled
            ? max(shadowPadding, shadowBlur + abs(CGFloat(style.shadow.offsetY))) * canvasScale * 2
            : 0
        let borderPad = style.border.enabled ? style.glyphBorderPadding(fontSize: renderSize) * 2 : 0
        let backgroundPadX = style.background.enabled ? CGFloat(max(0, style.background.paddingX)) * canvasScale * 2 : 0
        let backgroundPadY = style.background.enabled ? CGFloat(max(0, style.background.paddingY)) * canvasScale * 2 : 0
        return CGSize(
            width: max(1, ceil(bounding.width) + shadowX + borderPad + backgroundPadX + slack),
            height: max(1, ceil(bounding.height) + shadowY + borderPad + backgroundPadY + slack)
        )
    }
}
