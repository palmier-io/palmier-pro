import AppKit
import CoreText

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
        let visualScale = CGFloat(style.fontScale)
        let style = style.scaledVisualStyle
        let displayText = style.displayText(content)
        let measured = displayText.isEmpty ? " " : displayText
        let canvasScale = canvasHeight / referenceCanvasHeight
        let renderSize = CGFloat(style.fontSize) * canvasScale
        let str = NSAttributedString(
            string: measured,
            attributes: style.attributes(size: renderSize, includeColor: false)
        )
        let proposedMaxWidth = maxWidth * visualScale
        let scaledMaxWidth = proposedMaxWidth.isFinite ? proposedMaxWidth : .greatestFiniteMagnitude
        let bounding = suggestedSize(for: str, maxWidth: scaledMaxWidth)
        // Four reference pixels absorb canvas→preview scale rounding.
        let slack = max(0, visualScale) * 4
        let shadowBlur = max(0, CGFloat(style.shadow.blur))
        let shadowX = style.shadow.enabled
            ? max(shadowPadding * visualScale, shadowBlur + abs(CGFloat(style.shadow.offsetX))) * canvasScale * 2
            : 0
        let shadowY = style.shadow.enabled
            ? max(shadowPadding * visualScale, shadowBlur + abs(CGFloat(style.shadow.offsetY))) * canvasScale * 2
            : 0
        let borderPad = style.border.enabled ? style.glyphBorderPadding(fontSize: renderSize) * 2 : 0
        let backgroundPadX = style.background.enabled ? CGFloat(max(0, style.background.paddingX)) * canvasScale * 2 : 0
        let backgroundPadY = style.background.enabled ? CGFloat(max(0, style.background.paddingY)) * canvasScale * 2 : 0
        return CGSize(
            width: max(1, ceil(bounding.width) + shadowX + borderPad + backgroundPadX + slack),
            height: max(1, ceil(bounding.height) + shadowY + borderPad + backgroundPadY + slack)
        )
    }

    static func frame(
        for attributedString: NSAttributedString,
        in box: CGRect,
        verticallySizedFor sizingString: NSAttributedString? = nil
    ) -> CTFrame {
        let textFramesetter = framesetter(for: attributedString)
        let measurementString = measurementString(for: sizingString ?? attributedString)
        let measurementFramesetter = measurementString === attributedString
            ? textFramesetter
            : framesetter(for: measurementString)
        let contentHeight = suggestedSize(using: measurementFramesetter, maxWidth: box.width).height
        let frameHeight = min(box.height, ceil(contentHeight))
        let centeredBox = CGRect(
            x: box.minX,
            y: box.midY - frameHeight / 2,
            width: box.width,
            height: frameHeight
        )
        let path = CGPath(rect: centeredBox, transform: nil)
        return CTFramesetterCreateFrame(textFramesetter, CFRange(location: 0, length: 0), path, nil)
    }

    private static func suggestedSize(for attributedString: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        suggestedSize(using: framesetter(for: measurementString(for: attributedString)), maxWidth: maxWidth)
    }

    private static func measurementString(for attributedString: NSAttributedString) -> NSAttributedString {
        if attributedString.string.last?.isNewline == true {
            // CoreText omits a final empty line unless measurement includes a zero-width glyph.
            let mutable = NSMutableAttributedString(attributedString: attributedString)
            var attributes = attributedString.attributes(at: attributedString.length - 1, effectiveRange: nil)
            attributes[.kern] = 0
            mutable.append(NSAttributedString(string: "\u{200B}", attributes: attributes))
            return mutable
        }
        return attributedString
    }

    private static func suggestedSize(using framesetter: CTFramesetter, maxWidth: CGFloat) -> CGSize {
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            nil
        )
    }

    private static func framesetter(for attributedString: NSAttributedString) -> CTFramesetter {
        CTFramesetterCreateWithAttributedString(attributedString as CFAttributedString)
    }
}
