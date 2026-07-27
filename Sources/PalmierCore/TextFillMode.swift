import Foundation

public enum TextFillMode: String, Codable, Sendable, CaseIterable {
    case color
    case footage

    public var displayName: String {
        switch self {
        case .color: "Color"
        case .footage: "Footage"
        }
    }
}
