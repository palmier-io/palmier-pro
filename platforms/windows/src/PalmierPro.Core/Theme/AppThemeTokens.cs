namespace PalmierPro.Core.Theme;

/// (X,Y) direction/position pair — WinRT-free stand-in for CGPoint / SwiftUI UnitPoint.
public readonly record struct ThemePoint(double X, double Y);

/// (Width,Height) pair — WinRT-free stand-in for NSSize.
public readonly record struct ThemeSize(double Width, double Height);

/// One gradient color stop.
public readonly record struct GradientStop(uint Color, double Location);

/// A linear gradient: ordered stops plus a start/end direction (SwiftUI UnitPoint values baked
/// to normalized 0..1 coordinates, e.g. .topLeading = (0,0), .trailing = (1,0.5)).
public sealed class GradientToken
{
    public required GradientStop[] Stops { get; init; }
    public required ThemePoint Start { get; init; }
    public required ThemePoint End { get; init; }
}

/// A drop shadow: AARRGGBB color + blur radius + offset. Mirrors AppTheme.ShadowStyle.
public readonly record struct ShadowToken(uint Color, double Radius, double X, double Y);

/// <summary>
/// Design tokens ported verbatim from Sources/PalmierPro/UI/AppTheme.swift (411 lines, 29
/// categories). Every nested class name and member name mirrors the Swift declaration 1:1
/// (PascalCase for C#'s casing convention). Values are primitives only — uint 0xAARRGGBB for
/// colors, double for sizes/opacities/durations — so this project stays WinRT-free and
/// ThemeParityTests can run under plain `dotnet test`. PalmierPro.App/Theme/AppTheme.cs adapts
/// these into Windows.UI.Color / SolidColorBrush / CornerRadius / etc; Theme.xaml exposes the
/// same values as XAML StaticResources for direct use in markup.
/// </summary>
public static class AppThemeTokens
{
    private static byte ToByte(double component) =>
        (byte)Math.Round(Math.Clamp(component, 0.0, 1.0) * 255.0, MidpointRounding.AwayFromZero);

    private static uint Argb(double a, double r, double g, double b) =>
        ((uint)ToByte(a) << 24) | ((uint)ToByte(r) << 16) | ((uint)ToByte(g) << 8) | ToByte(b);

    /// 0-255 byte components, opaque alpha. Mirrors NSColor(red: n/255, green: n/255, blue: n/255, alpha: 1).
    private static uint Rgb(int r, int g, int b) => 0xFF000000u | ((uint)r << 16) | ((uint)g << 8) | (uint)b;

    private static uint Gray(double white, double alpha = 1.0) => Argb(alpha, white, white, white);

    /// Mirrors NSColor.withAlphaComponent / Color.opacity — replaces only the alpha channel.
    private static uint WithAlpha(uint colorArgb, double alpha) => (colorArgb & 0x00FFFFFFu) | ((uint)ToByte(alpha) << 24);

    private const uint White = 0xFFFFFFFFu;
    private const uint Black = 0xFF000000u;

    public static class Background
    {
        public static readonly uint Base = Rgb(10, 10, 10);
        public static readonly uint Surface = Rgb(22, 22, 22);
        public static readonly uint Raised = Rgb(30, 30, 30);
        public static readonly uint Prominent = Rgb(44, 44, 44);

        /// Alias — empty media slot is a raised plate.
        public static readonly uint Placeholder = Raised;

        public static readonly uint PreviewCanvas = Black;
        public const uint Clear = 0x00000000u;
    }

    public static class Border
    {
        public static readonly uint Primary = Gray(1.0, 0.16);
        public static readonly uint Subtle = Gray(1.0, 0.12);
        public static readonly uint Divider = Gray(1.0, 0.44);
        public const uint TimelineClip = Black;
    }

    public static class BorderWidth
    {
        public const double Hairline = 0.5;
        public const double Thin = 1;
        public const double Medium = 1.5;
        public const double Thick = 2;
    }

    public static class Accent
    {
        public static readonly uint Timecode = Argb(1.0, 0.95, 0.6, 0.2);

        /// Warm off-white
        public static readonly uint Primary = Argb(1.0, 0.961, 0.937, 0.894);

        /// Vibrant highlight used by the onboarding tour spotlight.
        public static readonly uint Spotlight = Argb(1.0, 1.0, 0.27, 0.27);

        public static readonly GradientToken SpotlightGradient = new()
        {
            Stops =
            [
                new GradientStop(Argb(1.0, 1.0, 0.34, 0.30), 0.0),
                new GradientStop(Argb(1.0, 0.95, 0.15, 0.28), 0.5),
                new GradientStop(Argb(1.0, 1.0, 0.48, 0.22), 1.0),
            ],
            Start = new ThemePoint(0, 0), // .topLeading
            End = new ThemePoint(1, 1), // .bottomTrailing
        };
    }

    public static class Update
    {
        public static readonly uint Accent = AppThemeTokens.Accent.Timecode;
    }

    public static class Slider
    {
        public const double TrackHeight = 4;
        public const double ThumbSize = 10;
        public const double LabelColumn = 106;

        /// Temperature track: cool blue (low) → warm amber (high).
        public static readonly GradientToken TempGradient = TwoStop(Argb(1.0, 0.32, 0.55, 0.92), Argb(1.0, 0.95, 0.72, 0.32));

        /// Tint track: green (low) → magenta (high).
        public static readonly GradientToken TintGradient = TwoStop(Argb(1.0, 0.42, 0.78, 0.45), Argb(1.0, 0.82, 0.38, 0.72));

        /// Master luma track: near-black → near-white.
        public static readonly GradientToken LumaGradient = TwoStop(Gray(0.05), Gray(0.95));

        /// Swift builds these as `LinearGradient(colors: [a, b], startPoint: .leading, endPoint: .trailing)`.
        private static GradientToken TwoStop(uint start, uint end) => new()
        {
            Stops = [new GradientStop(start, 0.0), new GradientStop(end, 1.0)],
            Start = new ThemePoint(0, 0.5), // .leading
            End = new ThemePoint(1, 0.5), // .trailing
        };
    }

    public static class AudioMeter
    {
        public const double PanelWidth = 32;
        public const double BarWidth = 8;
        public const double RefreshInterval = 1.0 / 30.0;
        public const double RulerStepDb = 6;
        public const double RulerMajorStepDb = 12;
        public const double YellowThresholdDb = -20;
        public const double RedThresholdDb = -6;

        public static readonly uint GreenSegment = Argb(1.0, 0.08, 0.78, 0.22);
        public static readonly uint YellowSegment = Argb(1.0, 0.98, 0.84, 0.10);
        public static readonly uint RedSegment = Argb(1.0, 0.90, 0.24, 0.20);
    }

    public static class Wheels
    {
        public const double PadSize = 96;
        public const double PuckSize = 10;
        public const double RingWidth = 1;
        public static readonly uint CrosshairColor = WithAlpha(White, Opacity.Faint);
    }

    public static class Curve
    {
        public const double EditorHeight = 180;
        public const double PointDiameter = 9;

        /// Invisible grab target around each point — much larger than the dot so it's easy to hit.
        public const double PointHitDiameter = 30;

        public static readonly uint LumaColor = Argb(1.0, 1, 1, 1);
        public static readonly uint RedColor = Argb(1.0, 1, 0.22, 0.18);
        public static readonly uint GreenColor = Argb(1.0, 0.32, 0.82, 0.36);
        public static readonly uint BlueColor = Argb(1.0, 0.32, 0.56, 1);
    }

    /// Monochrome silver shimmer. Top-level in Swift (not nested in a category) — kept top-level here too.
    public static readonly GradientToken AiGradient = new()
    {
        Stops =
        [
            new GradientStop(Gray(1.00), 0.00),
            new GradientStop(Gray(0.78), 0.45),
            new GradientStop(Gray(0.60), 0.55),
            new GradientStop(Gray(1.00), 1.00),
        ],
        Start = new ThemePoint(0, 0), // .topLeading
        End = new ThemePoint(1, 1), // .bottomTrailing
    };

    public static readonly GradientToken AiGradientDark = new()
    {
        Stops =
        [
            new GradientStop(Gray(0.11), 0.00),
            new GradientStop(Gray(0.06), 1.00),
        ],
        Start = new ThemePoint(0.5, 0), // .top
        End = new ThemePoint(0.5, 1), // .bottom
    };

    public static class Glass
    {
        public static readonly uint PrimaryTint = WithAlpha(Accent.Primary, 0.05);
    }

    public static class Status
    {
        public static readonly uint Error = Rgb(0xE5, 0x4F, 0x4F);
        public static readonly uint Success = Rgb(0x4F, 0xB8, 0x5F);

        /// NSColor.systemOrange, Dark Aqua sRGB value — every Mac window forces `.darkAqua` appearance.
        public static readonly uint Warning = Rgb(0xFF, 0x9F, 0x0A);
    }

    public static class Text
    {
        public static readonly uint Primary = Gray(1.0, 1.0);
        public static readonly uint Secondary = Gray(1.0, 0.80);
        public static readonly uint Tertiary = Gray(1.0, 0.62);
        public static readonly uint Muted = Gray(1.0, 0.34);
    }

    public static class Opacity
    {
        public const double Opaque = 1;
        public const double Subtle = 0.04;
        public const double Hint = 0.06;
        public const double Faint = 0.08;
        public const double Soft = 0.10;
        public const double Muted = 0.15;
        public const double Moderate = 0.25;
        public const double Medium = 0.35;
        public const double Strong = 0.55;
        public const double High = 0.70;
        public const double Prominent = 0.80;
    }

    public static class TrackColor
    {
        public static readonly uint Video = Rgb(0x1D, 0x58, 0x78);
        public static readonly uint Audio = Rgb(0x2E, 0x77, 0x65);
        public static readonly uint Image = Rgb(0x71, 0x54, 0x86);
        public static readonly uint Text = Rgb(0x71, 0x54, 0x86);
        public static readonly uint Lottie = Rgb(0xA0, 0x78, 0x22);
        public static readonly uint Sequence = Rgb(0xB9, 0xB2, 0x9A);

        /// NSColor.systemRed, Dark Aqua sRGB value — every Mac window forces `.darkAqua` appearance.
        public static readonly uint Multicam = Rgb(0xFF, 0x45, 0x3A);
    }

    public static class Radius
    {
        public const double Xs = 3;
        public const double XsSm = 4;
        public const double Sm = 6;
        public const double Md = 10;
        public const double MdLg = 12;
        public const double Lg = 14;
        public const double Xl = 20;

        public static double Concentric(double outer, double padding) => Math.Max(outer - padding, 0);
    }

    public static class Spacing
    {
        public const double Zero = 0;
        public const double Xxs = 2;
        public const double Xs = 4;
        public const double Sm = 6;
        public const double SmMd = 8;
        public const double Md = 10;
        public const double MdLg = 12;
        public const double Lg = 14;
        public const double LgXl = 16;
        public const double Xl = 20;
        public const double XlXxl = 24;
        public const double Xxl = 28;
    }

    public static class FontSize
    {
        public const double Micro = 8;
        public const double Xxs = 9;
        public const double Xs = 10;
        public const double Sm = 11;
        public const double SmMd = 12;
        public const double Md = 13;
        public const double MdLg = 14;
        public const double Lg = 15;
        public const double Xl = 18;
        public const double Title1 = 22;
        public const double Title2 = 28;
        public const double Display = 36;
    }

    /// OpenType numeric weights (100-900) — SwiftUI's Font.Weight has no public raw value; this is
    /// the standard mapping DirectWrite/XAML FontWeight and variable-font `wght` axes also use.
    public static class FontWeight
    {
        public const int Light = 300;
        public const int Regular = 400;
        public const int Medium = 500;
        public const int Semibold = 600;
        public const int Bold = 700;
    }

    public static class Tracking
    {
        public const double Tight = -0.5;
        public const double Normal = 0;
        public const double Wide = 1.5;
    }

    public static class IconSize
    {
        public const double Xxs = 12;
        public const double Xs = 14;
        public const double Sm = 18;
        public const double SmMd = 20;
        public const double Md = 22;
        public const double MdLg = 24;
        public const double Lg = 26;
        public const double LgXl = 28;
        public const double Xl = 30;
    }

    public static class ComponentSize
    {
        public const double CaptionPreviewMaxHeight = 150;
        public const double CaptionPreviewMaxTextWidthRatio = 0.9;
        public const double ToolImagePreviewMaxHeight = 50;
        public const double ProjectCardWidth = 150;
        public const double ProjectCardHeight = 120;
        public const double TimelineClipBorderMinWidth = 8;
        public const double TimelineClipDetailMinWidth = 32;
        public const double TimelineTabRenameWidth = 120;
        public const double TimelineClipLabelMinWidth = 56;
        public const double TimelineBadgePadH = 4;
        public const double TimelineBadgePadV = 1;
        public const double TimelineBadgeMinWidth = 16;
        public const double TimelineDotSize = 5;
        public const double UpdateOverlayWidth = 640;

        /// Preview transport bar (M4) — the Mac hardcodes these directly in
        /// PreviewContainerView.swift (`transportBar`'s `.frame(height: 36)` and
        /// `transportButton`'s `.frame(width: 32, height: 28)`) rather than routing them through
        /// AppTheme; ported here as real tokens since this port's AGENTS.md requires every UI size
        /// to come from AppTheme.
        public const double TransportBarHeight = 36;
        public const double TransportButtonWidth = 32;
        public const double TransportButtonHeight = 28;

        /// Preview source-asset scrub bar (M4) — mirrors PreviewContainerView.swift's `scrubBar`
        /// (`.frame(height: 12)`) and its inactive-state capsule thickness (`barHeight: CGFloat = 3`
        /// when neither hovered nor dragging; this port doesn't yet grow the bar on hover/drag).
        public const double PreviewScrubBarHeight = 12;
        public const double PreviewScrubTrackHeight = 3;
    }

    public static class Window
    {
        public static readonly ThemeSize HomeDefault = new(1200, 880);
        public static readonly ThemeSize HomeMin = new(760, 480);
        public static readonly ThemeSize ProjectMin = new(960, 600);
        public const double ProjectTitlebarTrailingWidth = 280;
        public static readonly ThemeSize SettingsDefault = new(1200, 900);
        public static readonly ThemeSize SettingsMin = new(860, 640);
    }

    public static class Caption
    {
        public const double DefaultFontSize = 48;
        public const double MinFontSize = 12;
        public const double MaxFontSize = 300;
        public const double MinPosition = 0;
        public const double MaxPosition = 1;
        public const double CenterSnapValue = 0.5;
        public const double CenterSnapThreshold = 0.02;
        public const double DefaultCenterY = 0.9;
        public static readonly ThemePoint DefaultCenter = new(CenterSnapValue, DefaultCenterY);
        public const double MinDisplayDuration = 0.7;
    }

    public static class GenerationPanel
    {
        public const double MediaAreaMinHeight = 120;
        public const double LoadingHeight = 180;
        public const double PromptMinHeight = 40;
        public const double ReferenceTileWidth = 80;
        public const double ReferenceTileHeight = 56;
    }

    public static class MediaPanel
    {
        public const double TabRailWidth = IconSize.Lg + Spacing.Sm * 2;
        public const double ContextRowHeight = IconSize.Md;

        /// Default asset/folder grid tile width — matches Mac's ThumbnailPreset.medium.
        public const double ThumbnailTileWidth = 110;

        /// Locked 16:9 thumbnail-box height for <see cref="ThumbnailTileWidth"/> — mirrors
        /// MediaTileScaffold.swift's `.aspectRatio(16.0/9.0, contentMode: .fit)` on the artwork
        /// ZStack (the Mac derives height from whatever width the grid gives the tile; Windows'
        /// tile width is fixed, so this bakes the same ratio in at that fixed width instead).
        public const double ThumbnailTileHeight = ThumbnailTileWidth * 9.0 / 16.0;

        /// MediaTabView's toolbar search field width. No Mac equivalent: MediaTab.swift's
        /// `searchField` TextField has no fixed width at all — it just flows inside its toolbar
        /// HStack. This Windows-only fixed width is a port-time addition (WinUI's `Grid`/toolbar
        /// layout here needs an explicit size), kept as a token instead of a bare XAML literal.
        public const double SearchFieldWidth = 180;
    }

    public static class Export
    {
        public const double SheetWidth = 600;
        public const double SheetHeight = 600;
        public const double LogPaneWidth = 420;
        public const double QueueTimestampWidth = 56;
        public const double ActivityDotSize = 6;
        public const double QueueProgressBarWidth = 96;
        public const double QueueProgressWidth = 32;
        public const double SheetWidthWithLog = SheetWidth + LogPaneWidth + BorderWidth.Hairline;
    }

    public static class Matte
    {
        public const double SheetWidth = 280;
        public const double ControlWidth = 116;
    }

    /// Inspector property-row metrics — mirrors Inspector/Keyframes/KeyframesLane.swift's
    /// `KeyframesMetrics` (rowHeight/stampButtonWidth/navButtonWidth/rulerHeight/stripHeight),
    /// ported as real AppTheme tokens per this port's AGENTS.md rather than a standalone
    /// Swift-style enum. `LabelColumn` isn't repeated here — the row label reuses
    /// <see cref="Slider"/>.LabelColumn for alignment with every other Inspector row.
    public static class Inspector
    {
        public const double RowHeight = 22;
        public const double StampButtonWidth = 22;
        public const double NavButtonWidth = 6;

        /// Rotated-square keyframe stamp glyph side length (before the 45° rotation).
        public const double DiamondSize = 8;

        /// Keyframes tab's per-clip ruler + clip-strip header (KeyframesMetrics.rulerHeight/
        /// stripHeight) — the compact timecode ruler above the property lanes.
        public const double RulerHeight = 18;
        public const double StripHeight = 14;
    }

    public static class Shadow
    {
        public static readonly ShadowToken Sm = new(WithAlpha(Black, 0.3), 1, 0, 0.5);
        public static readonly ShadowToken Md = new(WithAlpha(Black, 0.3), 4, 0, 2);
        public static readonly ShadowToken Lg = new(WithAlpha(Black, 0.25), 24, 0, 8);
    }

    public static class Anim
    {
        public const double Hover = 0.15;
        public const double Transition = 0.2;
        public const double Pulse = 0.8;
    }

    /// NEW — the Mac has no family token; UI chrome renders in the OS system font (SF Pro) via
    /// ~475 bare `.system(size:)` call sites. Apple's license forbids shipping SF Pro off Apple
    /// platforms, so Windows chrome uses Inter (OFL-licensed, already bundled under
    /// Sources/PalmierPro/Resources/Fonts/Inter/) as the sanctioned substitution.
    public static class FontFamily
    {
        public const string Ui = "Inter";
    }
}
