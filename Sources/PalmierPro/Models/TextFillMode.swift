import Foundation

enum TextFillMode: String, Codable, Sendable, CaseIterable {
    case color
    case footage

    var displayName: String {
        switch self {
        case .color: "Color"
        case .footage: "Footage"
        }
    }
}

extension Clip {
    mutating func setTextFillMode(_ mode: TextFillMode?) {
        textFillMode = captionGroupId == nil && mode == .footage ? .footage : nil
        stripFootageIncompatibleTextStyle()
    }

    mutating func stripFootageIncompatibleTextStyle() {
        guard textFillMode == .footage else { return }
        if var style = textStyle {
            style.shadow = TextStyle.Shadow(enabled: false)
            style.background = TextStyle.Background()
            style.border = TextStyle.Outline()
            textStyle = style
        }
        if var anim = textAnimation {
            anim.highlight = nil
            if anim.preset == .highlightPop || anim.preset == .highlightBlock {
                textAnimation = nil
            } else {
                textAnimation = anim
            }
        }
        effects = nil
    }
}
