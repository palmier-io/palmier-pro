import AppKit
import Foundation

/// OKLCH → sRGB conversion. Neutral endpoints are exact (black 0/0/0, white 1/1/1) and output
/// channels are clamped to [0, 1].
enum OKLCHConverter {
    struct OKLCH: Hashable, Sendable {
        var lightness: Double
        var chroma: Double
        var hue: Double
        var alpha: Double = 1
    }

    struct SRGB: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    static func convert(_ color: OKLCH) -> SRGB {
        guard color.lightness.isFinite, color.chroma.isFinite, color.hue.isFinite, color.alpha.isFinite else {
            return SRGB(red: 0, green: 0, blue: 0, alpha: 1)
        }
        let lightness = min(1, max(0, color.lightness))
        let chroma = max(0, color.chroma)
        let hue = color.hue.truncatingRemainder(dividingBy: 360) * .pi / 180
        let a = chroma * cos(hue)
        let b = chroma * sin(hue)

        // OKLab → LMS'
        let l = lightness + 0.3963377774 * a + 0.2158037573 * b
        let m = lightness - 0.1055613458 * a - 0.0638541728 * b
        let s = lightness - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l * l * l
        let m3 = m * m * m
        let s3 = s * s * s

        // LMS → linear sRGB
        let red = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let green = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let blue = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        return SRGB(
            red: gamma(clamp(red)),
            green: gamma(clamp(green)),
            blue: gamma(clamp(blue)),
            alpha: min(1, max(0, color.alpha))
        )
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func gamma(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}

extension NSColor {
    convenience init(_ color: OKLCHConverter.SRGB) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

/// Semantic colors keyed by appearance. Instances are immutable and cached per appearance, so
/// repeated resolution returns the same instance.
struct OKLCHTheme: Sendable, Equatable {
    let background: OKLCHConverter.SRGB
    let card: OKLCHConverter.SRGB
    let primary: OKLCHConverter.SRGB
    let accent: OKLCHConverter.SRGB
    let destructive: OKLCHConverter.SRGB
    let border: OKLCHConverter.SRGB
    let chart1: OKLCHConverter.SRGB
    let chart2: OKLCHConverter.SRGB
    let chart3: OKLCHConverter.SRGB
    let chart4: OKLCHConverter.SRGB
    let chart5: OKLCHConverter.SRGB
    let sidebarBackground: OKLCHConverter.SRGB
    let sidebarForeground: OKLCHConverter.SRGB
    let radius: Double

    static let dark = OKLCHTheme(
        background: OKLCHConverter.convert(.init(lightness: 0.145, chroma: 0, hue: 0)),
        card: OKLCHConverter.convert(.init(lightness: 0.205, chroma: 0, hue: 0)),
        primary: OKLCHConverter.convert(.init(lightness: 0.922, chroma: 0, hue: 0)),
        accent: OKLCHConverter.convert(.init(lightness: 0.67, chroma: 0.16, hue: 250)),
        destructive: OKLCHConverter.convert(.init(lightness: 0.62, chroma: 0.2, hue: 25)),
        border: OKLCHConverter.convert(.init(lightness: 0.28, chroma: 0, hue: 0)),
        chart1: OKLCHConverter.convert(.init(lightness: 0.62, chroma: 0.18, hue: 250)),
        chart2: OKLCHConverter.convert(.init(lightness: 0.68, chroma: 0.16, hue: 155)),
        chart3: OKLCHConverter.convert(.init(lightness: 0.72, chroma: 0.15, hue: 80)),
        chart4: OKLCHConverter.convert(.init(lightness: 0.63, chroma: 0.19, hue: 20)),
        chart5: OKLCHConverter.convert(.init(lightness: 0.66, chroma: 0.17, hue: 320)),
        sidebarBackground: OKLCHConverter.convert(.init(lightness: 0.175, chroma: 0, hue: 0)),
        sidebarForeground: OKLCHConverter.convert(.init(lightness: 0.92, chroma: 0, hue: 0)),
        radius: 8
    )

    static let light = OKLCHTheme(
        background: OKLCHConverter.convert(.init(lightness: 1, chroma: 0, hue: 0)),
        card: OKLCHConverter.convert(.init(lightness: 0.97, chroma: 0, hue: 0)),
        primary: OKLCHConverter.convert(.init(lightness: 0.24, chroma: 0, hue: 0)),
        accent: OKLCHConverter.convert(.init(lightness: 0.55, chroma: 0.16, hue: 250)),
        destructive: OKLCHConverter.convert(.init(lightness: 0.55, chroma: 0.2, hue: 25)),
        border: OKLCHConverter.convert(.init(lightness: 0.9, chroma: 0, hue: 0)),
        chart1: OKLCHConverter.convert(.init(lightness: 0.55, chroma: 0.18, hue: 250)),
        chart2: OKLCHConverter.convert(.init(lightness: 0.6, chroma: 0.16, hue: 155)),
        chart3: OKLCHConverter.convert(.init(lightness: 0.65, chroma: 0.15, hue: 80)),
        chart4: OKLCHConverter.convert(.init(lightness: 0.56, chroma: 0.19, hue: 20)),
        chart5: OKLCHConverter.convert(.init(lightness: 0.58, chroma: 0.17, hue: 320)),
        sidebarBackground: OKLCHConverter.convert(.init(lightness: 0.96, chroma: 0, hue: 0)),
        sidebarForeground: OKLCHConverter.convert(.init(lightness: 0.24, chroma: 0, hue: 0)),
        radius: 8
    )

    /// Resolves the cached theme for an appearance; vibrant variants use their base scheme.
    @MainActor
    static func resolved(for appearance: NSAppearance) -> OKLCHTheme {
        let name = appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
        return name == .darkAqua ? dark : light
    }

    /// Falls back to the app's existing colors when a caller wants an NSColor.
    func color(for role: Role, appearance: NSAppearance) -> NSColor {
        NSColor(swatch(for: role))
    }

    enum Role: Sendable {
        case background, card, primary, accent, destructive, border, sidebarBackground, sidebarForeground
    }

    private func swatch(for role: Role) -> OKLCHConverter.SRGB {
        switch role {
        case .background: background
        case .card: card
        case .primary: primary
        case .accent: accent
        case .destructive: destructive
        case .border: border
        case .sidebarBackground: sidebarBackground
        case .sidebarForeground: sidebarForeground
        }
    }
}
