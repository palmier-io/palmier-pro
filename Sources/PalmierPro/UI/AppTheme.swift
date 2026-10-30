import AppKit
import SwiftUI

enum AppTheme {

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - Backgrounds

    enum Background {
        static let base = AppTheme.adaptive(
            light: NSColor(red: 241/255, green: 240/255, blue: 237/255, alpha: 1),
            dark: NSColor(red: 24/255, green: 25/255, blue: 28/255, alpha: 1)
        )
        static let surface = AppTheme.adaptive(
            light: NSColor(red: 245/255, green: 244/255, blue: 241/255, alpha: 1),
            dark: NSColor(red: 30/255, green: 31/255, blue: 35/255, alpha: 1)
        )
        static let raised = AppTheme.adaptive(
            light: NSColor(red: 249/255, green: 248/255, blue: 245/255, alpha: 1),
            dark: NSColor(red: 38/255, green: 39/255, blue: 44/255, alpha: 1)
        )
        static let prominent = AppTheme.adaptive(
            light: NSColor(red: 252/255, green: 251/255, blue: 248/255, alpha: 1),
            dark: NSColor(red: 48/255, green: 49/255, blue: 55/255, alpha: 1)
        )

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
        static let primary = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.20),
            dark: NSColor.white.withAlphaComponent(0.10)
        )
        static let subtle = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.14),
            dark: NSColor.white.withAlphaComponent(0.07)
        )
        static let divider = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.44),
            dark: NSColor.white.withAlphaComponent(0.24)
        )
        static let panel = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.18),
            dark: .black
        )
        static let timelineClip = AppTheme.adaptive(light: .white, dark: .black)
        static let timelineClipSelected = AppTheme.adaptive(light: .black, dark: .white)
        static let timelineMarker = AppTheme.adaptive(light: .white, dark: .black)
        static let timelineMarkerSelected = AppTheme.adaptive(light: .black, dark: .white)

        static var primaryColor: Color { Color(primary) }
        static var subtleColor: Color { Color(subtle) }
        static var dividerColor: Color { Color(divider) }
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
        static let timecodeNSColor = AppTheme.adaptive(
            light: NSColor(red: 0.58, green: 0.29, blue: 0.02, alpha: 1),
            dark: NSColor(red: 0.95, green: 0.6, blue: 0.2, alpha: 1)
        )
        static let timecodeColor = Color(timecodeNSColor)

        static let primaryNSColor = AppTheme.adaptive(
            light: NSColor(red: 48/255, green: 48/255, blue: 48/255, alpha: 1),
            dark: NSColor(red: 236/255, green: 236/255, blue: 236/255, alpha: 1)
        )
        static let primary = Color(primaryNSColor)

        static let playheadNSColor = AppTheme.adaptive(
            light: NSColor(srgbRed: 1.0, green: 0.18, blue: 0.16, alpha: 1),
            dark: NSColor(srgbRed: 1.0, green: 0.32, blue: 0.30, alpha: 1)
        )

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
        static var lumaColor: Color { AppTheme.Text.primaryColor }
        static let redColor = Color(red: 1, green: 0.22, blue: 0.18)
        static let greenColor = Color(red: 0.32, green: 0.82, blue: 0.36)
        static let blueColor = Color(red: 0.32, green: 0.56, blue: 1)
    }

    // MARK: - Status

    enum Status {
        static let error = AppTheme.adaptive(
            light: NSColor(red: 0.70, green: 0.14, blue: 0.09, alpha: 1),
            dark: NSColor(red: 0xE5/255.0, green: 0x4F/255.0, blue: 0x4F/255.0, alpha: 1)
        )

        static var errorColor: Color { Color(error) }

        static let success = AppTheme.adaptive(
            light: NSColor(red: 0.09, green: 0.45, blue: 0.28, alpha: 1),
            dark: NSColor(red: 0x4F/255.0, green: 0xB8/255.0, blue: 0x5F/255.0, alpha: 1)
        )

        static var successColor: Color { Color(success) }

        static let warning = NSColor.systemOrange

        static var warningColor: Color { Color(warning) }

        static var pendingColor: Color { Color(NSColor.systemYellow) }
    }

    enum AgentActivity {
        static let added = NSColor.systemGreen
        static let mutated = NSColor.systemOrange
        static let read = NSColor(
            srgbRed: 0x64 / 255.0,
            green: 0x74 / 255.0,
            blue: 0x8B / 255.0,
            alpha: 1
        )
        static let readFill = read.withAlphaComponent(AppTheme.Opacity.faint)
        static let changeGlowOpacity: Float = 0.8
        static let changeGlowRadius: CGFloat = 8
        static let readGlowOpacity: Float = 0.35
        static let readGlowRadius: CGFloat = 4
    }

    enum TimelineMarker {
        static let flagWidth: CGFloat = 10
        static let flagHeight: CGFloat = 12
        static let rangeBarHeight: CGFloat = 4
        static let hitSlop: CGFloat = 3
        static let editorWidth: CGFloat = 320
        static let timeFieldWidth: CGFloat = 82
        static let commentsHeight: CGFloat = 54
        static let presetColors = [
            "#4094FF", "#40CCE6", "#40BF5C", "#F2C72E", "#FF8C26", "#E64040", "#F259A6",
            "#A666F2", "#8CBFFF", "#73E6B8", "#A6D936", "#C79E6B", "#D1D1D1",
        ].compactMap(TextStyle.RGBA.init(hex:))
    }

    // MARK: - Text

    enum Text {
        static let primary = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.92),
            dark: NSColor.white.withAlphaComponent(0.98)
        )
        static let secondary = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.78),
            dark: NSColor.white.withAlphaComponent(0.84)
        )
        static let tertiary = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.66),
            dark: NSColor.white.withAlphaComponent(0.68)
        )
        static let muted = AppTheme.adaptive(
            light: NSColor.black.withAlphaComponent(0.46),
            dark: NSColor.white.withAlphaComponent(0.46)
        )

        static var primaryColor: Color { Color(primary) }
        static var secondaryColor: Color { Color(secondary) }
        static var tertiaryColor: Color { Color(tertiary) }
        static var mutedColor: Color { Color(muted) }
    }

    // MARK: - Interaction fills

    enum Interaction {
        static func fill(_ opacity: Double) -> Color {
            AppTheme.Text.primaryColor.opacity(opacity)
        }
    }

    // MARK: - Media overlays

    enum MediaOverlay {
        static let background = NSColor.black
        static let primary = NSColor.white
        static let secondary = NSColor.white.withAlphaComponent(0.80)
        static let tertiary = NSColor.white.withAlphaComponent(0.62)
        static let muted = NSColor.white.withAlphaComponent(0.34)
        static let error = NSColor(red: 0xE5/255.0, green: 0x4F/255.0, blue: 0x4F/255.0, alpha: 1)

        static var backgroundColor: Color { Color(background) }
        static var primaryColor: Color { Color(primary) }
        static var secondaryColor: Color { Color(secondary) }
        static var tertiaryColor: Color { Color(tertiary) }
        static var mutedColor: Color { Color(muted) }
        static var errorColor: Color { Color(error) }
    }

    // MARK: - Opacity

    enum Opacity {
        static let transparent: Double = 0
        static let opaque: Double = 1
        static let hitTarget: Double = 0.001
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
        static var video: NSColor { TimelineClipColorPalette.shared.color(for: .video) }
        static var audio: NSColor { TimelineClipColorPalette.shared.color(for: .audio) }
        static var image: NSColor { TimelineClipColorPalette.shared.color(for: .image) }
        static var text: NSColor { TimelineClipColorPalette.shared.color(for: .text) }
        static var lottie: NSColor { TimelineClipColorPalette.shared.color(for: .animation) }
        static var sequence: NSColor { TimelineClipColorPalette.shared.color(for: .sequence) }
        static let multicam = NSColor.systemRed

        static func readableForeground(on background: NSColor) -> NSColor {
            guard let background = background.usingColorSpace(.sRGB) else { return .white }
            let luminance = relativeLuminance(
                red: background.redComponent,
                green: background.greenComponent,
                blue: background.blueComponent
            )
            let blackContrast = (luminance + 0.05) / 0.05
            let whiteContrast = 1.05 / (luminance + 0.05)
            return blackContrast >= whiteContrast ? .black : .white
        }

        private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
            func linear(_ component: CGFloat) -> CGFloat {
                component <= 0.04045
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
        }
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
        static let captionPreviewMaxTextWidthRatio: CGFloat = 0.9
        static let toolImagePreviewMaxHeight: CGFloat = 50
        static let projectCardWidth: CGFloat = 150
        static let projectCardHeight: CGFloat = 120
        static let projectSearchWidth: CGFloat = 260
        static let timelineClipBorderMinWidth: CGFloat = 8
        static let timelineClipDetailMinWidth: CGFloat = 32
        static let timelineClipControlsMinWidth: CGFloat = 48
        static let timelineTabRenameWidth: CGFloat = 120
        static let timelineTrackHeaderDefaultWidth: CGFloat = 160
        static let timelineTrackHeaderMinimumWidth: CGFloat = 112
        static let timelineTrackHeaderMaximumWidth: CGFloat = 320
        static let timelineTrackHeaderResizeHitWidth: CGFloat = 8
        static let timelineTrackHeaderColorStripWidth: CGFloat = 3
        static let timelineTrackHeaderReorderLeadingInset: CGFloat = 9
        static let timelineKeyframeResizeHandleWidth: CGFloat =
            timelineTrackHeaderReorderLeadingInset + AppTheme.IconSize.md
        static let timelineKeyframeTrackHeaderMinimumWidth: CGFloat = 220
        static let timelineKeyframeValueFieldWidth: CGFloat = 36
        static let timelineKeyframeValueFieldHeight: CGFloat = 18
        static let timelineKeyframeLaneHeight: CGFloat = 24
        static let timelineKeyframeDiamondSize: CGFloat = 8
        static let timelineKeyframeHitSize: CGFloat = 14
        static let timelineClipLabelMinWidth: CGFloat = 56
        static let timelineBadgePadH: CGFloat = 4
        static let timelineBadgePadV: CGFloat = 1
        static let timelineBadgeMinWidth: CGFloat = 16
        static let timelineDotSize: CGFloat = 5
        static let updateOverlayWidth: CGFloat = 640
    }

    enum Onboarding {
        static let cardWidth: CGFloat = 520
        static let cardHeight: CGFloat = 420
        static let welcomeHeroHeight: CGFloat = 240
        static var secondaryButtonFill: Color {
            AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted)
        }
    }

    enum Settings {
        static let sidebarWidth: CGFloat = 220
        static let contentMaxWidth: CGFloat = 640
        static let creditInputWidth: CGFloat = 56
        static let skillsSearchWidth: CGFloat = 260
        static let skillRowIconFrame: CGFloat = 42
        static let skillStatusWidth: CGFloat = 124
        static let skillActionWidth: CGFloat = 112
        static let skillDetailWidth: CGFloat = 720
        static let skillDetailMinHeight: CGFloat = 600
        static let skillToastWidth: CGFloat = 380
        static let skillMenuWidth: CGFloat = 168
        static let skillToastDuration: Duration = .seconds(5)
    }

    enum EditorPanel {
        static let defaultWidth: CGFloat = 340
        static let minimumWidth: CGFloat = 300
        static let labelColumnWidth: CGFloat = 88
        static let rowMinHeight: CGFloat = 22
        static let groupHeaderHeight: CGFloat = 28
        static let fieldMinHeight: CGFloat = 22
        static let numericFieldWidth: CGFloat = 56
        static let compactNumericFieldWidth: CGFloat = 36
        static let fontMenuWidth: CGFloat = 160
        static let textEditorMinHeight: CGFloat = 96
        static let contentInsets = EdgeInsets(
            top: Spacing.smMd,
            leading: Spacing.smMd + IconSize.xs + Spacing.sm,
            bottom: Spacing.smMd,
            trailing: Spacing.smMd
        )
    }

    enum Window {
        static let homeDefault = NSSize(width: 1200, height: 800)
        static let homeMin = NSSize(width: 760, height: 480)
        static let projectMin = NSSize(
            width: 960 + GenerationPanel.minimumWidthAdjustment,
            height: 600
        )
        static let projectTitlebarLeadingWidth: CGFloat = 132
        static let projectTitlebarTrailingWidth: CGFloat = 280
        static let settingsDefault = NSSize(width: 1200, height: 800)
        static let settingsMin = NSSize(width: 860, height: 640)
    }

    enum Caption {
        static let defaultFontSize: Double = 48
        static let centerSnapValue: CGFloat = 0.5
        static let centerSnapThreshold: Double = 0.02
        static let defaultCenterY: CGFloat = 0.9
        static let defaultCenter = CGPoint(x: centerSnapValue, y: defaultCenterY)
    }

    enum GenerationPanel {
        static let typeTabWidth: CGFloat = IconSize.xl + Spacing.lg
        static let minimumWidthAdjustment: CGFloat = typeTabWidth + Spacing.xxl
        static let mediaAreaMinHeight: CGFloat = 60
        static let loadingHeight: CGFloat = 180
        static let promptMinHeight: CGFloat = 40
        static let referenceTileWidth: CGFloat = 72
        static let referenceTileHeight: CGFloat = 48
    }

    enum MediaPanel {
        static let contextRowHeight: CGFloat = IconSize.smMd
        static let speakerNameFieldWidth: CGFloat = 96
        static let captionIndexTimecodeWidth: CGFloat = 68
        static let captionIndexDurationWidth: CGFloat = 28
        static let transcriptSourceMenuWidth: CGFloat = 116
        static let markerIndexTimeFieldWidth: CGFloat = 64
        static let markerIndexDurationFieldWidth: CGFloat = 32
        static let markerIndexCommentHeight: CGFloat = 36
        static let markerIndexThumbnailHeight = EditorPanel.fieldMinHeight
            + Spacing.xs + markerIndexCommentHeight
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
        static let overlay = ShadowStyle(
            color: .black.opacity(Opacity.strong),
            radius: Spacing.xlXxl,
            x: 0,
            y: -Spacing.smMd
        )
    }

    // MARK: - Animation durations

    enum Anim {
        static let hover: Double = 0.15
        static let transition: Double = 0.2
        static let pulse: Double = 0.8
        static let slipPreviewRefresh: Duration = .milliseconds(67)
        static let agentChangeHighlightHold: Double = 1.0
        static let agentChangeHighlightFade: Double = 0.3
        static let agentChangeHighlightDuration = agentChangeHighlightHold + agentChangeHighlightFade
        static let agentReadHighlightHold: Double = 0.7
        static let agentReadHighlightFade: Double = 0.25
        static let agentReadHighlightDuration = agentReadHighlightHold + agentReadHighlightFade
    }
}

// MARK: - Shadow view modifier

extension View {
    func shadow(_ style: AppTheme.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }

    func panelHeaderBar(
        backgroundColor: Color = AppTheme.Background.surfaceColor
    ) -> some View {
        frame(maxWidth: .infinity)
            .frame(height: Layout.panelHeaderHeight)
            .background(backgroundColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppTheme.Border.primaryColor)
                    .frame(height: AppTheme.BorderWidth.thin)
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
        case .subtitle: AppTheme.TrackColor.text
        }
    }

    var themeForegroundColor: NSColor {
        AppTheme.TrackColor.readableForeground(on: themeColor)
    }
}
