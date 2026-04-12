import AppKit
import SwiftUI

enum AppTheme {

    // MARK: - Backgrounds (3-tier depth hierarchy)

    enum Background {
        /// Darkest – content wells: preview area, timeline body
        static let well = NSColor(white: 0.07, alpha: 1)
        /// Mid – panel bodies: media panel, inspector
        static let panel = NSColor(white: 0.10, alpha: 1)
        /// Lightest – bars: toolbars, tab bars, headers
        static let bar = NSColor(white: 0.13, alpha: 1)

        static var wellColor: Color { Color(well) }
        static var panelColor: Color { Color(panel) }
        static var barColor: Color { Color(bar) }
    }

    // MARK: - Borders

    enum Border {
        static let primary = NSColor.white.withAlphaComponent(0.08)
        static let subtle = NSColor.white.withAlphaComponent(0.05)

        static var primaryColor: Color { Color(primary) }
        static var subtleColor: Color { Color(subtle) }
    }

    // MARK: - Accent

    enum Accent {
        static let timecodeColor = Color(red: 0.95, green: 0.6, blue: 0.2) // warm amber
    }

    // MARK: - Text

    enum Text {
        static let primary = NSColor.white.withAlphaComponent(0.92)
        static let secondary = NSColor.white.withAlphaComponent(0.60)
        static let tertiary = NSColor.white.withAlphaComponent(0.40)
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
    }

    // MARK: - Clip fills

    enum ClipFill {
        static let base = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        static let selected = NSColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1)
    }

    // MARK: - Corner radii

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
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
        }
    }
}
