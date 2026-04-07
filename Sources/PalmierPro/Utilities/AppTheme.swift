import AppKit
import SwiftUI

enum AppTheme {

    // MARK: - Borders

    enum Border {
        static let primary = NSColor.white.withAlphaComponent(0.08)
        static let subtle = NSColor.white.withAlphaComponent(0.05)

        static var primaryColor: Color { Color(primary) }
        static var subtleColor: Color { Color(subtle) }
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
        static let video = NSColor(red: 0.165, green: 0.624, blue: 0.831, alpha: 1) // cyan
        static let audio = NSColor(red: 0.361, green: 0.722, blue: 0.086, alpha: 1) // lime
        static let image = NSColor(red: 0.639, green: 0.345, blue: 0.878, alpha: 1) // purple
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
