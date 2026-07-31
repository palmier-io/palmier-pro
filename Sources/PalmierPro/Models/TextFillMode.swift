import Foundation

enum TextFillMode: String, Codable, Sendable, CaseIterable {
    case color
    case footage

    var displayName: String {
        switch self {
        case .color: L10n.key("Color")
        case .footage: L10n.key("Footage")
        }
    }
}
