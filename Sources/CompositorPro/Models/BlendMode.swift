import Foundation

/// How a visual clip composites over the layers below it. `normal` = source-over.
enum BlendMode: String, Codable, Sendable, CaseIterable {
    case normal, darken, multiply, colorBurn, lighten, screen, colorDodge
    case overlay, softLight, hardLight, difference, exclusion
    case hue, saturation, color, luminosity

    var displayName: String {
        switch self {
        case .normal: L10n.key("Normal")
        case .darken: L10n.key("Darken")
        case .multiply: L10n.key("Multiply")
        case .colorBurn: L10n.key("Color Burn")
        case .lighten: L10n.key("Lighten")
        case .screen: L10n.key("Screen")
        case .colorDodge: L10n.key("Color Dodge")
        case .overlay: L10n.key("Overlay")
        case .softLight: L10n.key("Soft Light")
        case .hardLight: L10n.key("Hard Light")
        case .difference: L10n.key("Difference")
        case .exclusion: L10n.key("Exclusion")
        case .hue: L10n.key("Hue")
        case .saturation: L10n.key("Saturation")
        case .color: L10n.key("Color")
        case .luminosity: L10n.key("Luminosity")
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
