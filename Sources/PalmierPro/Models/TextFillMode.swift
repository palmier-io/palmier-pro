import Foundation

enum TextFillMode: String, Codable, Sendable, CaseIterable {
    case color
    case footage
    case inverted

    var displayName: String {
        switch self {
        case .color: L10n.key("Color")
        case .footage: L10n.key("Footage")
        case .inverted: L10n.key("Inverted")
        }
    }
}
