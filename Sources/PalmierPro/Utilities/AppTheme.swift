import AppKit
import SwiftUI

enum AppTheme {

    // MARK: - Backgrounds

    enum Background {
        /// Base – content areas, panels, timeline body, wells
        static let surface = NSColor(white: 0.07, alpha: 1)

        static var surfaceColor: Color { Color(surface) }
    }

    // MARK: - Borders

    enum Border {
        static let primary = NSColor.white.withAlphaComponent(0.12)
        static let subtle = NSColor.white.withAlphaComponent(0.08)
        static let divider = NSColor.white.withAlphaComponent(0.35)

        static var primaryColor: Color { Color(primary) }
        static var subtleColor: Color { Color(subtle) }
    }

    // MARK: - Accent

    enum Accent {
        static let timecodeColor = Color(red: 0.95, green: 0.6, blue: 0.2) // warm amber
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
        /// Tint reserved for primary action buttons only (Export, New Project)
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

    // MARK: - Track type colors

    enum TrackColor {
        static let video = NSColor(red: 0x00/255.0, green: 0x6D/255.0, blue: 0x94/255.0, alpha: 1) // #006d94
        static let audio = NSColor(red: 0x3D/255.0, green: 0x7A/255.0, blue: 0x0A/255.0, alpha: 1) // #3d7a0a
        static let image = NSColor(red: 0x96/255.0, green: 0x15/255.0, blue: 0xAD/255.0, alpha: 1) // #9615ad
        static let text = NSColor(red: 0x96/255.0, green: 0x15/255.0, blue: 0xAD/255.0, alpha: 1) // #9615ad (same as image)
    }

    // MARK: - Clip fills

    enum ClipFill {
        static let base = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        static let selected = NSColor(red: 0.15, green: 0.15, blue: 0.19, alpha: 1)
    }

    // MARK: - Corner radii

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20

        /// Concentric inner radius: outer radius minus padding, floored at 0
        static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(outer - padding, 0)
        }
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
    }

    // MARK: - Font sizes

    enum FontSize {
        static let xs: CGFloat = 10
        static let sm: CGFloat = 11
        static let md: CGFloat = 13
        static let lg: CGFloat = 15
        static let xl: CGFloat = 18
    }

    // MARK: - Animation durations

    enum Anim {
        static let hover: Double = 0.15
        static let transition: Double = 0.2
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
