import Foundation

/// How a visual clip composites over the layers below it. `normal` = source-over.
enum BlendMode: String, Codable, Sendable, CaseIterable {
    case normal, darken, multiply, colorBurn, lighten, screen, colorDodge
    case overlay, softLight, hardLight, difference, exclusion
    case hue, saturation, color, luminosity

    var displayName: String {
        switch self {
        case .normal: L10n.string("Normal")
        case .darken: L10n.string("Darken")
        case .multiply: L10n.string("Multiply")
        case .colorBurn: L10n.string("Color Burn")
        case .lighten: L10n.string("Lighten")
        case .screen: L10n.string("Screen")
        case .colorDodge: L10n.string("Color Dodge")
        case .overlay: L10n.string("Overlay")
        case .softLight: L10n.string("Soft Light")
        case .hardLight: L10n.string("Hard Light")
        case .difference: L10n.string("Difference")
        case .exclusion: L10n.string("Exclusion")
        case .hue: L10n.string("Hue")
        case .saturation: L10n.string("Saturation")
        case .color: L10n.string("Color")
        case .luminosity: L10n.string("Luminosity")
        }
    }

    /// Core Image blend-filter name; nil for `normal` (plain source-over compositing).
    var ciFilterName: String? {
        switch self {
        case .normal: nil
        case .darken: "CIDarkenBlendMode"
        case .multiply: "CIMultiplyBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .lighten: "CILightenBlendMode"
        case .screen: "CIScreenBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .color: "CIColorBlendMode"
        case .luminosity: "CILuminosityBlendMode"
        }
    }
}
