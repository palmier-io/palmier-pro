import Foundation

/// Colour grade carried by an adjustment-layer clip. All slider values are
/// neutral at `0`, so a default grade is the identity transform.
struct ColorGrade: Codable, Sendable, Equatable {
    var temperature: Double = 0    // −100…100
    var tint: Double = 0           // −100…100
    var exposure: Double = 0       // −100…100 (±2 EV)
    var contrast: Double = 0       // −100…100
    var saturation: Double = 0     // −100…100
    var lutRef: String?            // package-relative .cube filename; nil = no LUT
    var lutIntensity: Double = 1   // 0…1
    var basicEnabled: Bool = true
    var creativeEnabled: Bool = true

    var hasBasicEffect: Bool {
        basicEnabled && (temperature != 0 || tint != 0 || exposure != 0 || contrast != 0 || saturation != 0)
    }

    var hasLUTEffect: Bool {
        creativeEnabled && lutRef != nil && lutIntensity > 0
    }

    var hasEffect: Bool { hasBasicEffect || hasLUTEffect }
}

/// How a visual clip composites over the layers below it. `normal` = source-over.
enum BlendMode: String, Codable, Sendable, CaseIterable {
    case normal, darken, multiply, colorBurn, lighten, screen, colorDodge
    case overlay, softLight, hardLight, difference, exclusion
    case hue, saturation, color, luminosity

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    /// Core Image blend-filter name; nil for `normal` (use source-over compositing).
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

/// Per-clip chroma key (Ultra Key). Defaults to a green screen.
struct ChromaKey: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var keyColor: TextStyle.RGBA = TextStyle.RGBA(r: 0, g: 1, b: 0, a: 1)
    var tolerance: Double = 40     // 0…100
    var softness: Double = 20      // 0…100
    var spill: Double = 50         // 0…100
    var edgeFeather: Double = 0    // points

    var isActive: Bool { enabled }
}
