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
