import AppKit
import SwiftUI

enum AppTheme {

    // MARK: - Backgrounds

    enum Background {
        static let surface = NSColor(white: 0.07, alpha: 1)
        static let placeholder = NSColor(white: 0.10, alpha: 1)

        static var surfaceColor: Color { Color(surface) }
        static var placeholderColor: Color { Color(placeholder) }
    }

    // MARK: - Borders

    enum Border {
        static let primary = NSColor.white.withAlphaComponent(0.12)
        static let subtle = NSColor.white.withAlphaComponent(0.08)
        static let divider = NSColor.white.withAlphaComponent(0.35)

        static var primaryColor: Color { Color(primary) }
        static var subtleColor: Color { Color(subtle) }
    }

    // MARK: - Border widths

    enum BorderWidth {
        static let hairline: CGFloat = 0.5
        static let thin: CGFloat = 1
        static let medium: CGFloat = 1.5
        static let thick: CGFloat = 2
    }

    // MARK: - Accent

    enum Accent {
        static let timecodeColor = Color(red: 0.95, green: 0.6, blue: 0.2)
    }

    static let aiGradient = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.55, blue: 0.20),
            Color(red: 0.98, green: 0.36, blue: 0.58),
            Color(red: 0.67, green: 0.36, blue: 0.96),
            Color(red: 0.29, green: 0.60, blue: 0.99),
            Color(red: 0.25, green: 0.85, blue: 0.95),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Glass

    enum Glass {
        static let primaryTint = Color.accentColor.opacity(0.05)
    }

    // MARK: - Text

    enum Text {
        static let primary = NSColor.white.withAlphaComponent(0.96)
        static let secondary = NSColor.white.withAlphaComponent(0.70)
        static let tertiary = NSColor.white.withAlphaComponent(0.50)
        static let muted = NSColor.white.withAlphaComponent(0.25)

        static var primaryColor: Color { Color(primary) }
        static var secondaryColor: Color { Color(secondary) }
        static var tertiaryColor: Color { Color(tertiary) }
        static var mutedColor: Color { Color(muted) }
    }

    // MARK: - Opacity

    enum Opacity {
        static let subtle: Double = 0.04
        static let hint: Double = 0.06
        static let faint: Double = 0.08
        static let soft: Double = 0.10
        static let muted: Double = 0.15
        static let moderate: Double = 0.25
        static let medium: Double = 0.35
        static let strong: Double = 0.55
        static let prominent: Double = 0.80
    }

    // MARK: - Track type colors

    enum TrackColor {
        static let video = NSColor(red: 0x00/255.0, green: 0x6D/255.0, blue: 0x94/255.0, alpha: 1)
        static let audio = NSColor(red: 0x3D/255.0, green: 0x7A/255.0, blue: 0x0A/255.0, alpha: 1)
        static let image = NSColor(red: 0x96/255.0, green: 0x15/255.0, blue: 0xAD/255.0, alpha: 1)
        static let text = NSColor(red: 0x96/255.0, green: 0x15/255.0, blue: 0xAD/255.0, alpha: 1)
    }

    // MARK: - Corner radii

    enum Radius {
        static let xs: CGFloat = 3
        static let xsSm: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let mdLg: CGFloat = 12
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20

        static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(outer - padding, 0)
        }
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let smMd: CGFloat = 8
        static let md: CGFloat = 10
        static let mdLg: CGFloat = 12
        static let lg: CGFloat = 14
        static let lgXl: CGFloat = 16
        static let xl: CGFloat = 20
        static let xlXxl: CGFloat = 24
        static let xxl: CGFloat = 28
    }

    // MARK: - Font sizes

    enum FontSize {
        static let micro: CGFloat = 8
        static let xxs: CGFloat = 9
        static let xs: CGFloat = 10
        static let sm: CGFloat = 11
        static let smMd: CGFloat = 12
        static let md: CGFloat = 13
        static let mdLg: CGFloat = 14
        static let lg: CGFloat = 15
        static let xl: CGFloat = 18
        static let title1: CGFloat = 22
        static let title2: CGFloat = 28
        static let display: CGFloat = 36
    }

    // MARK: - Font weights

    enum FontWeight {
        static let regular: Font.Weight = .regular
        static let medium: Font.Weight = .medium
        static let semibold: Font.Weight = .semibold
        static let bold: Font.Weight = .bold
    }

    // MARK: - Icon sizes (square frame dimensions)

    enum IconSize {
        static let xs: CGFloat = 14
        static let sm: CGFloat = 18
        static let smMd: CGFloat = 20
        static let md: CGFloat = 22
        static let mdLg: CGFloat = 24
        static let lg: CGFloat = 26
        static let lgXl: CGFloat = 28
        static let xl: CGFloat = 30
    }

    // MARK: - Shadows

    struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Shadow {
        static let sm = ShadowStyle(color: .black.opacity(0.3), radius: 1, x: 0, y: 0.5)
        static let md = ShadowStyle(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        static let lg = ShadowStyle(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
    }

    // MARK: - Animation durations

    enum Anim {
        static let hover: Double = 0.15
        static let transition: Double = 0.2
    }
}

// MARK: - Shadow view modifier

extension View {
    func shadow(_ style: AppTheme.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}

// MARK: - ClipType color mapping

extension ClipType {
    var themeColor: NSColor {
        switch self {
        case .video: AppTheme.TrackColor.video
        case .audio: AppTheme.TrackColor.audio
        case .image: AppTheme.TrackColor.image
        case .text: AppTheme.TrackColor.text
        }
    }
}
