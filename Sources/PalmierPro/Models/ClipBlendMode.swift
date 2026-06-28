import Foundation

enum ClipBlendMode: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten
    case difference
    case exclusion

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .darken: "Darken"
        case .lighten: "Lighten"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        }
    }

    var coreImageFilterName: String? {
        switch self {
        case .normal: nil
        case .multiply: "CIMultiplyBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .darken: "CIDarkenBlendMode"
        case .lighten: "CILightenBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        }
    }
}
