import AppKit

/// Natural bounding size of a rendered text clip, shared between the layer
/// controller and clip placement.
enum TextLayout {
    static let shadowPadding: CGFloat = 12

    static func naturalSize(content: String, style: TextStyle, maxWidth: CGFloat) -> CGSize {
        let measured = content.isEmpty ? " " : content
        let str = NSAttributedString(
            string: measured,
            attributes: style.attributes(size: CGFloat(style.fontSize), includeColor: false)
        )
        let bounding = str.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // +4px slack absorbs canvas→preview scale rounding.
        let slack: CGFloat = 4
        return CGSize(
            width: max(1, ceil(bounding.width) + shadowPadding * 2 + slack),
            height: max(1, ceil(bounding.height) + shadowPadding * 2 + slack)
        )
    }
}
