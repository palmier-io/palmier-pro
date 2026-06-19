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
