import AppKit
import SwiftUI

enum AppTheme {

    // MARK: - Backgrounds

    enum Background {
        static let base = NSColor(red: 10/255, green: 10/255, blue: 10/255, alpha: 1)
        static let surface = NSColor(red: 22/255, green: 22/255, blue: 22/255, alpha: 1)
        static let raised = NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        static let prominent = NSColor(red: 44/255, green: 44/255, blue: 44/255, alpha: 1)

        /// Alias — empty media slot is a raised plate.
        static let placeholder = raised

        static var baseColor: Color { Color(base) }
        static var surfaceColor: Color { Color(surface) }
        static var raisedColor: Color { Color(raised) }
        static var prominentColor: Color { Color(prominent) }
        static var previewCanvasColor: Color { .black }
        static var placeholderColor: Color { Color(placeholder) }
        static var clearColor: Color { .clear }
    }

    // MARK: - Borders

    enum Border {
        static let primary = NSColor.white.withAlphaComponent(0.16)
        static let subtle = NSColor.white.withAlphaComponent(0.12)
        static let divider = NSColor.white.withAlphaComponent(0.44)
        static let timelineClip = NSColor.black

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
        static let timecodeNSColor = NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1)
        static let timecodeColor = Color(timecodeNSColor)

        /// Warm off-white
        static let primary = Color(red: 0.961, green: 0.937, blue: 0.894)

        static let link = Color(nsColor: .linkColor)

        /// Vibrant highlight used by the onboarding tour spotlight.
        static let spotlight = Color(red: 1.0, green: 0.27, blue: 0.27)
        static let spotlightGradient = LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.34, blue: 0.30),
                Color(red: 0.95, green: 0.15, blue: 0.28),
                Color(red: 1.0, green: 0.48, blue: 0.22),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    enum Update {
        static let accent = Accent.timecodeColor
    }

    // MARK: - Adjust sliders

    enum Slider {
        static let trackHeight: CGFloat = 4
        static let thumbSize: CGFloat = 10
        static let labelColumn: CGFloat = 106
        /// Temperature track: cool blue (low) → warm amber (high).
        static let tempGradient = [Color(red: 0.32, green: 0.55, blue: 0.92), Color(red: 0.95, green: 0.72, blue: 0.32)]
        /// Tint track: green (low) → magenta (high).
        static let tintGradient = [Color(red: 0.42, green: 0.78, blue: 0.45), Color(red: 0.82, green: 0.38, blue: 0.72)]
        /// Master luma track: near-black → near-white.
        static let lumaGradient = [Color(white: 0.05), Color(white: 0.95)]
    }

    enum AudioMeter {
        static let panelWidth: CGFloat = 32
        static let barWidth: CGFloat = 8
        static let refreshInterval: Double = 1.0 / 30.0
        static let rulerStepDb: Float = 6
        static let rulerMajorStepDb: Float = 12
        static let yellowThresholdDb: Float = -20
        static let redThresholdDb: Float = -6

        static let greenSegment = Color(red: 0.08, green: 0.78, blue: 0.22)
        static let yellowSegment = Color(red: 0.98, green: 0.84, blue: 0.10)
        static let redSegment = Color(red: 0.90, green: 0.24, blue: 0.20)
    }

    // MARK: - Color wheels

    enum Wheels {
        static let padSize: CGFloat = 96
        static let puckSize: CGFloat = 10
        static let ringWidth: CGFloat = 1
        static let crosshairColor = Color.white.opacity(AppTheme.Opacity.faint)
    }

    enum Curve {
        static let editorHeight: CGFloat = 180
        static let pointDiameter: CGFloat = 9
        /// Invisible grab target around each point — much larger than the dot so it's easy to hit.
        static let pointHitDiameter: CGFloat = 30
        static let lumaColor = Color(red: 1, green: 1, blue: 1)
        static let redColor = Color(red: 1, green: 0.22, blue: 0.18)
        static let greenColor = Color(red: 0.32, green: 0.82, blue: 0.36)
        static let blueColor = Color(red: 0.32, green: 0.56, blue: 1)
    }

    /// Monochrome silver shimmer
    static let aiGradient = LinearGradient(
        stops: [
            .init(color: Color(white: 1.00), location: 0.00),
            .init(color: Color(white: 0.78), location: 0.45),
            .init(color: Color(white: 0.60), location: 0.55),
            .init(color: Color(white: 1.00), location: 1.00),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let aiGradientDark = LinearGradient(
        stops: [
            .init(color: Color(white: 0.11), location: 0.00),
            .init(color: Color(white: 0.06), location: 1.00),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Status

    enum Status {
        static let error = NSColor(red: 0xE5/255.0, green: 0x4F/255.0, blue: 0x4F/255.0, alpha: 1)

        static var errorColor: Color { Color(error) }

        static let success = NSColor(red: 0x4F/255.0, green: 0xB8/255.0, blue: 0x5F/255.0, alpha: 1)

        static var successColor: Color { Color(success) }

        static let warning = NSColor.systemOrange

        static var warningColor: Color { Color(warning) }
    }

    // MARK: - Text

    enum Text {
        static let primary = NSColor.white.withAlphaComponent(1.0)
        static let secondary = NSColor.white.withAlphaComponent(0.80)
        static let tertiary = NSColor.white.withAlphaComponent(0.62)
        static let muted = NSColor.white.withAlphaComponent(0.34)

        static var primaryColor: Color { Color(primary) }
        static var secondaryColor: Color { Color(secondary) }
        static var tertiaryColor: Color { Color(tertiary) }
        static var mutedColor: Color { Color(muted) }
    }

    // MARK: - Opacity

    enum Opacity {
        static let opaque: Double = 1
        static let subtle: Double = 0.04
        static let hint: Double = 0.06
        static let faint: Double = 0.08
        static let soft: Double = 0.10
        static let muted: Double = 0.15
        static let moderate: Double = 0.25
        static let medium: Double = 0.35
        static let strong: Double = 0.55
        static let high: Double = 0.70
        static let prominent: Double = 0.80
    }

    // MARK: - Track type colors

    enum TrackColor {
        static let video = NSColor(red: 0x1D/255.0, green: 0x58/255.0, blue: 0x78/255.0, alpha: 1)
        static let audio = NSColor(red: 0x2E/255.0, green: 0x77/255.0, blue: 0x65/255.0, alpha: 1)
        static let image = NSColor(red: 0x71/255.0, green: 0x54/255.0, blue: 0x86/255.0, alpha: 1)
        static let text = NSColor(red: 0x71/255.0, green: 0x54/255.0, blue: 0x86/255.0, alpha: 1)
        static let lottie = NSColor(red: 0xA0/255.0, green: 0x78/255.0, blue: 0x22/255.0, alpha: 1)
        static let sequence = NSColor(red: 0xB9/255.0, green: 0xB2/255.0, blue: 0x9A/255.0, alpha: 1)
        static let multicam = NSColor.systemRed
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
        static let zero: CGFloat = 0
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
        static let light: Font.Weight = .light
        static let regular: Font.Weight = .regular
        static let medium: Font.Weight = .medium
        static let semibold: Font.Weight = .semibold
        static let bold: Font.Weight = .bold
    }

    // MARK: - Tracking (letter-spacing)

    enum Tracking {
        static let tight: CGFloat = -0.5
        static let normal: CGFloat = 0
        static let wide: CGFloat = 1.5
    }

    // MARK: - Icon sizes (square frame dimensions)

    enum IconSize {
        static let xxs: CGFloat = 12
        static let xs: CGFloat = 14
        static let sm: CGFloat = 18
        static let smMd: CGFloat = 20
        static let md: CGFloat = 22
        static let mdLg: CGFloat = 24
        static let lg: CGFloat = 26
        static let lgXl: CGFloat = 28
        static let xl: CGFloat = 30
    }

    enum ComponentSize {
        static let captionPreviewMaxHeight: CGFloat = 150
        static let captionPreviewMaxTextWidthRatio: CGFloat = 0.9
        static let toolImagePreviewMaxHeight: CGFloat = 50
        static let projectCardWidth: CGFloat = 150
        static let projectCardHeight: CGFloat = 120
        static let timelineClipBorderMinWidth: CGFloat = 8
        static let timelineClipDetailMinWidth: CGFloat = 32
        static let timelineTabRenameWidth: CGFloat = 120
        static let timelineClipLabelMinWidth: CGFloat = 56
        static let timelineBadgePadH: CGFloat = 4
        static let timelineBadgePadV: CGFloat = 1
        static let timelineBadgeMinWidth: CGFloat = 16
        static let timelineDotSize: CGFloat = 5
        static let updateOverlayWidth: CGFloat = 640
    }

    enum Settings {
        static let sidebarWidth: CGFloat = 220
        static let contentMaxWidth: CGFloat = 640
        static let creditInputWidth: CGFloat = 56
        static let skillsSearchWidth: CGFloat = 260
        static let skillRowIconFrame: CGFloat = 42
        static let skillStatusWidth: CGFloat = 124
        static let skillActionWidth: CGFloat = 72
        static let skillDetailWidth: CGFloat = 720
        static let skillDetailMinHeight: CGFloat = 600
        static let skillToastWidth: CGFloat = 380
        static let skillMenuWidth: CGFloat = 168
        static let skillToastDuration: Duration = .seconds(5)
    }

    enum EditorPanel {
        static let defaultWidth: CGFloat = 340
        static let minimumWidth: CGFloat = 240
        static let labelColumnWidth: CGFloat = 88
        static let rowMinHeight: CGFloat = 22
        static let groupHeaderHeight: CGFloat = 28
        static let tabBarHeight: CGFloat = 34
        static let fieldMinHeight: CGFloat = 22
        static let numericFieldWidth: CGFloat = 56
        static let compactNumericFieldWidth: CGFloat = 36
        static let fontMenuWidth: CGFloat = 160
        static let textEditorMinHeight: CGFloat = 96
    }

    enum Window {
        static let homeDefault = NSSize(width: 1200, height: 800)
        static let homeMin = NSSize(width: 760, height: 480)
        static let projectMin = NSSize(width: 960, height: 600)
        static let projectTitlebarTrailingWidth: CGFloat = 280
        static let settingsDefault = NSSize(width: 1200, height: 800)
        static let settingsMin = NSSize(width: 860, height: 640)
    }

    enum Caption {
        static let defaultFontSize: Double = 48
        static let minPosition: Double = 0
        static let maxPosition: Double = 1
        static let centerSnapValue: CGFloat = 0.5
        static let centerSnapThreshold: Double = 0.02
        static let defaultCenterY: CGFloat = 0.9
        static let defaultCenter = CGPoint(x: centerSnapValue, y: defaultCenterY)
        static let minDisplayDuration: Double = 0.7
    }

    enum GenerationPanel {
        static let mediaAreaMinHeight: CGFloat = 120
        static let loadingHeight: CGFloat = 180
        static let promptMinHeight: CGFloat = 40
        static let referenceTileWidth: CGFloat = 80
        static let referenceTileHeight: CGFloat = 56
    }

    enum MediaPanel {
        static let tabRailWidth: CGFloat = IconSize.lg + Spacing.sm * 2
        static let contextRowHeight: CGFloat = IconSize.md
    }

    enum Export {
        static let sheetWidth: CGFloat = 600
        static let sheetHeight: CGFloat = 600
        static let logPaneWidth: CGFloat = 420
        static let queueTimestampWidth: CGFloat = 56
        static let activityDotSize: CGFloat = 6
        static let queueProgressBarWidth: CGFloat = 96
        static let queueProgressWidth: CGFloat = 32
        static let sheetWidthWithLog: CGFloat = sheetWidth + logPaneWidth + BorderWidth.hairline
    }

    enum Matte {
        static let sheetWidth: CGFloat = 280
        static let controlWidth: CGFloat = 116
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
        static let pulse: Double = 0.8
    }
}

// MARK: - Shadow view modifier

extension View {
    func shadow(_ style: AppTheme.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    func panelHeaderBar() -> some View {
        frame(maxWidth: .infinity)
            .frame(height: Layout.panelHeaderHeight)
            .background(AppTheme.Background.raisedColor)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.thin)
            }
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
        case .lottie: AppTheme.TrackColor.lottie
        case .sequence: AppTheme.TrackColor.sequence
        }
    }
}
