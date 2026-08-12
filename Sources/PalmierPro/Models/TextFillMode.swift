import Foundation

enum TextFillMode: String, Codable, Sendable, CaseIterable {
    case color
    case footage
    case inverted

    static let defaultFootageMatteColor = TextStyle.RGBA(r: 0, g: 0, b: 0, a: 1)

    var displayName: String {
        switch self {
        case .color: L10n.key("Color")
        case .footage: L10n.key("Footage")
        case .inverted: L10n.key("Inverted")
        }
    }
}

extension Clip {
    mutating func setTextFillMode(
        _ mode: TextFillMode,
        footageMatteColor: TextStyle.RGBA? = nil
    ) {
        if mode == .footage, textFillMode != .footage {
            var style = textStyle ?? TextStyle()
            style.color = footageMatteColor ?? TextFillMode.defaultFootageMatteColor
            textStyle = style
        }
        textFillMode = mode == .color ? nil : mode
    }
}
