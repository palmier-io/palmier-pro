using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using PalmierPro.Core.Theme;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests.Theme;

/// <summary>
/// Asserts every numeric/color resource in Theme.xaml matches PalmierPro.Core.Theme.AppThemeTokens.
/// Parses Theme.xaml as plain XML (XDocument) — never XamlReader, which needs a packaged WinUI
/// host that plain `dotnet test` doesn't provide (see platforms/windows/AGENTS.md).
/// </summary>
public class ThemeParityTests
{
    private static readonly XNamespace Ns = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly XNamespace X = "http://schemas.microsoft.com/winfx/2006/xaml";
    private static readonly Regex StaticResourceRef = new(@"^\{StaticResource\s+(\w+)\}$");

    private static string ThemeXamlPath([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "..", "src", "PalmierPro.App", "Theme", "Theme.xaml"));

    private static Dictionary<string, XElement> LoadResources()
    {
        var doc = XDocument.Load(ThemeXamlPath());
        return doc.Descendants()
            .Where(e => e.Attribute(X + "Key") is not null)
            .ToDictionary(e => e.Attribute(X + "Key")!.Value, e => e);
    }

    private static readonly Dictionary<string, XElement> Resources = LoadResources();

    private static uint ParseHexColor(string text) => Convert.ToUInt32(text.Trim().TrimStart('#'), 16);

    private static double ParseDouble(string text) => double.Parse(text.Trim(), CultureInfo.InvariantCulture);

    private static uint ResolveColor(string key)
    {
        var el = Resources[key];
        return el.Name.LocalName switch
        {
            "Color" => ParseHexColor(el.Value),
            "SolidColorBrush" => ResolveBrushColor(el),
            _ => throw new InvalidOperationException($"'{key}' is a <{el.Name.LocalName}>, expected Color or SolidColorBrush."),
        };
    }

    /// SolidColorBrush.Color is either a literal "#AARRGGBB" or a "{StaticResource OtherKey}" indirection.
    private static uint ResolveBrushColor(XElement brush)
    {
        var raw = brush.Attribute("Color")!.Value;
        var match = StaticResourceRef.Match(raw);
        return match.Success ? ResolveColor(match.Groups[1].Value) : ParseHexColor(raw);
    }

    private static double ResolveDouble(string key) => ParseDouble(Resources[key].Value);

    private static int ResolveInt(string key) => int.Parse(Resources[key].Value.Trim(), CultureInfo.InvariantCulture);

    private static ThemePoint ResolvePoint(string raw)
    {
        var parts = raw.Split(',');
        return new ThemePoint(ParseDouble(parts[0]), ParseDouble(parts[1]));
    }

    private static GradientToken ResolveGradient(string key)
    {
        var el = Resources[key];
        var stops = el.Elements(Ns + "GradientStop")
            .Select(s => new GradientStop(ParseHexColor(s.Attribute("Color")!.Value), ParseDouble(s.Attribute("Offset")!.Value)))
            .ToArray();
        return new GradientToken
        {
            Stops = stops,
            Start = ResolvePoint(el.Attribute("StartPoint")!.Value),
            End = ResolvePoint(el.Attribute("EndPoint")!.Value),
        };
    }

    // Every color/brush resource, keyed to the Core token it must equal. Brush entries resolve
    // their StaticResource indirection back to the same Core value, catching a brush wired to the
    // wrong Color key as well as a wrong Color value.
    public static IEnumerable<object[]> ColorTokens()
    {
        (string Key, uint Expected)[] entries =
        [
            ("AppBackgroundBase", AppThemeTokens.Background.Base),
            ("AppBackgroundBaseBrush", AppThemeTokens.Background.Base),
            ("AppBackgroundSurface", AppThemeTokens.Background.Surface),
            ("AppBackgroundSurfaceBrush", AppThemeTokens.Background.Surface),
            ("AppBackgroundRaised", AppThemeTokens.Background.Raised),
            ("AppBackgroundRaisedBrush", AppThemeTokens.Background.Raised),
            ("AppBackgroundProminent", AppThemeTokens.Background.Prominent),
            ("AppBackgroundProminentBrush", AppThemeTokens.Background.Prominent),
            ("AppBackgroundPlaceholder", AppThemeTokens.Background.Placeholder),
            ("AppBackgroundPlaceholderBrush", AppThemeTokens.Background.Placeholder),
            ("AppBackgroundPreviewCanvas", AppThemeTokens.Background.PreviewCanvas),
            ("AppBackgroundPreviewCanvasBrush", AppThemeTokens.Background.PreviewCanvas),
            ("AppBackgroundClear", AppThemeTokens.Background.Clear),
            ("AppBackgroundClearBrush", AppThemeTokens.Background.Clear),

            ("AppBorderPrimary", AppThemeTokens.Border.Primary),
            ("AppBorderPrimaryBrush", AppThemeTokens.Border.Primary),
            ("AppBorderSubtle", AppThemeTokens.Border.Subtle),
            ("AppBorderSubtleBrush", AppThemeTokens.Border.Subtle),
            ("AppBorderDivider", AppThemeTokens.Border.Divider),
            ("AppBorderDividerBrush", AppThemeTokens.Border.Divider),
            ("AppBorderTimelineClip", AppThemeTokens.Border.TimelineClip),
            ("AppBorderTimelineClipBrush", AppThemeTokens.Border.TimelineClip),

            ("AppAccentTimecode", AppThemeTokens.Accent.Timecode),
            ("AppAccentTimecodeBrush", AppThemeTokens.Accent.Timecode),
            ("AppAccentPrimary", AppThemeTokens.Accent.Primary),
            ("AppAccentPrimaryBrush", AppThemeTokens.Accent.Primary),
            ("AppAccentSpotlight", AppThemeTokens.Accent.Spotlight),
            ("AppAccentSpotlightBrush", AppThemeTokens.Accent.Spotlight),

            ("AppUpdateAccent", AppThemeTokens.Update.Accent),
            ("AppUpdateAccentBrush", AppThemeTokens.Update.Accent),

            ("AppAudioMeterGreenSegment", AppThemeTokens.AudioMeter.GreenSegment),
            ("AppAudioMeterGreenSegmentBrush", AppThemeTokens.AudioMeter.GreenSegment),
            ("AppAudioMeterYellowSegment", AppThemeTokens.AudioMeter.YellowSegment),
            ("AppAudioMeterYellowSegmentBrush", AppThemeTokens.AudioMeter.YellowSegment),
            ("AppAudioMeterRedSegment", AppThemeTokens.AudioMeter.RedSegment),
            ("AppAudioMeterRedSegmentBrush", AppThemeTokens.AudioMeter.RedSegment),

            ("AppWheelsCrosshairColor", AppThemeTokens.Wheels.CrosshairColor),
            ("AppWheelsCrosshairColorBrush", AppThemeTokens.Wheels.CrosshairColor),

            ("AppCurveLumaColor", AppThemeTokens.Curve.LumaColor),
            ("AppCurveLumaColorBrush", AppThemeTokens.Curve.LumaColor),
            ("AppCurveRedColor", AppThemeTokens.Curve.RedColor),
            ("AppCurveRedColorBrush", AppThemeTokens.Curve.RedColor),
            ("AppCurveGreenColor", AppThemeTokens.Curve.GreenColor),
            ("AppCurveGreenColorBrush", AppThemeTokens.Curve.GreenColor),
            ("AppCurveBlueColor", AppThemeTokens.Curve.BlueColor),
            ("AppCurveBlueColorBrush", AppThemeTokens.Curve.BlueColor),

            ("AppGlassPrimaryTint", AppThemeTokens.Glass.PrimaryTint),
            ("AppGlassPrimaryTintBrush", AppThemeTokens.Glass.PrimaryTint),

            ("AppStatusError", AppThemeTokens.Status.Error),
            ("AppStatusErrorBrush", AppThemeTokens.Status.Error),
            ("AppStatusSuccess", AppThemeTokens.Status.Success),
            ("AppStatusSuccessBrush", AppThemeTokens.Status.Success),
            ("AppStatusWarning", AppThemeTokens.Status.Warning),
            ("AppStatusWarningBrush", AppThemeTokens.Status.Warning),

            ("AppTextPrimary", AppThemeTokens.Text.Primary),
            ("AppTextPrimaryBrush", AppThemeTokens.Text.Primary),
            ("AppTextSecondary", AppThemeTokens.Text.Secondary),
            ("AppTextSecondaryBrush", AppThemeTokens.Text.Secondary),
            ("AppTextTertiary", AppThemeTokens.Text.Tertiary),
            ("AppTextTertiaryBrush", AppThemeTokens.Text.Tertiary),
            ("AppTextMuted", AppThemeTokens.Text.Muted),
            ("AppTextMutedBrush", AppThemeTokens.Text.Muted),

            ("AppTrackColorVideo", AppThemeTokens.TrackColor.Video),
            ("AppTrackColorVideoBrush", AppThemeTokens.TrackColor.Video),
            ("AppTrackColorAudio", AppThemeTokens.TrackColor.Audio),
            ("AppTrackColorAudioBrush", AppThemeTokens.TrackColor.Audio),
            ("AppTrackColorImage", AppThemeTokens.TrackColor.Image),
            ("AppTrackColorImageBrush", AppThemeTokens.TrackColor.Image),
            ("AppTrackColorText", AppThemeTokens.TrackColor.Text),
            ("AppTrackColorTextBrush", AppThemeTokens.TrackColor.Text),
            ("AppTrackColorLottie", AppThemeTokens.TrackColor.Lottie),
            ("AppTrackColorLottieBrush", AppThemeTokens.TrackColor.Lottie),
            ("AppTrackColorSequence", AppThemeTokens.TrackColor.Sequence),
            ("AppTrackColorSequenceBrush", AppThemeTokens.TrackColor.Sequence),
            ("AppTrackColorMulticam", AppThemeTokens.TrackColor.Multicam),
            ("AppTrackColorMulticamBrush", AppThemeTokens.TrackColor.Multicam),

            ("AppShadowSmColor", AppThemeTokens.Shadow.Sm.Color),
            ("AppShadowMdColor", AppThemeTokens.Shadow.Md.Color),
            ("AppShadowLgColor", AppThemeTokens.Shadow.Lg.Color),
        ];
        foreach (var e in entries)
        {
            yield return [e.Key, e.Expected];
        }
    }

    [Theory]
    [MemberData(nameof(ColorTokens))]
    public void ColorResourceMatchesToken(string xamlKey, uint expected)
    {
        var actual = ResolveColor(xamlKey);
        actual.ShouldBe(expected, $"{xamlKey}: XAML=0x{actual:X8} Core=0x{expected:X8}");
    }

    // Every plain-numeric resource, keyed to the Core token it must equal (double tolerance guards
    // against literal-precision drift, not real value mismatches).
    public static IEnumerable<object[]> DoubleTokens()
    {
        (string Key, double Expected)[] entries =
        [
            ("AppBorderWidthHairline", AppThemeTokens.BorderWidth.Hairline),
            ("AppBorderWidthThin", AppThemeTokens.BorderWidth.Thin),
            ("AppBorderWidthMedium", AppThemeTokens.BorderWidth.Medium),
            ("AppBorderWidthThick", AppThemeTokens.BorderWidth.Thick),

            ("AppSliderTrackHeight", AppThemeTokens.Slider.TrackHeight),
            ("AppSliderThumbSize", AppThemeTokens.Slider.ThumbSize),
            ("AppSliderLabelColumn", AppThemeTokens.Slider.LabelColumn),

            ("AppAudioMeterPanelWidth", AppThemeTokens.AudioMeter.PanelWidth),
            ("AppAudioMeterBarWidth", AppThemeTokens.AudioMeter.BarWidth),
            ("AppAudioMeterRefreshInterval", AppThemeTokens.AudioMeter.RefreshInterval),
            ("AppAudioMeterRulerStepDb", AppThemeTokens.AudioMeter.RulerStepDb),
            ("AppAudioMeterRulerMajorStepDb", AppThemeTokens.AudioMeter.RulerMajorStepDb),
            ("AppAudioMeterYellowThresholdDb", AppThemeTokens.AudioMeter.YellowThresholdDb),
            ("AppAudioMeterRedThresholdDb", AppThemeTokens.AudioMeter.RedThresholdDb),

            ("AppWheelsPadSize", AppThemeTokens.Wheels.PadSize),
            ("AppWheelsPuckSize", AppThemeTokens.Wheels.PuckSize),
            ("AppWheelsRingWidth", AppThemeTokens.Wheels.RingWidth),

            ("AppCurveEditorHeight", AppThemeTokens.Curve.EditorHeight),
            ("AppCurvePointDiameter", AppThemeTokens.Curve.PointDiameter),
            ("AppCurvePointHitDiameter", AppThemeTokens.Curve.PointHitDiameter),

            ("AppOpacityOpaque", AppThemeTokens.Opacity.Opaque),
            ("AppOpacitySubtle", AppThemeTokens.Opacity.Subtle),
            ("AppOpacityHint", AppThemeTokens.Opacity.Hint),
            ("AppOpacityFaint", AppThemeTokens.Opacity.Faint),
            ("AppOpacitySoft", AppThemeTokens.Opacity.Soft),
            ("AppOpacityMuted", AppThemeTokens.Opacity.Muted),
            ("AppOpacityModerate", AppThemeTokens.Opacity.Moderate),
            ("AppOpacityMedium", AppThemeTokens.Opacity.Medium),
            ("AppOpacityStrong", AppThemeTokens.Opacity.Strong),
            ("AppOpacityHigh", AppThemeTokens.Opacity.High),
            ("AppOpacityProminent", AppThemeTokens.Opacity.Prominent),

            ("AppRadiusXs", AppThemeTokens.Radius.Xs),
            ("AppRadiusXsSm", AppThemeTokens.Radius.XsSm),
            ("AppRadiusSm", AppThemeTokens.Radius.Sm),
            ("AppRadiusMd", AppThemeTokens.Radius.Md),
            ("AppRadiusMdLg", AppThemeTokens.Radius.MdLg),
            ("AppRadiusLg", AppThemeTokens.Radius.Lg),
            ("AppRadiusXl", AppThemeTokens.Radius.Xl),

            ("AppSpacingZero", AppThemeTokens.Spacing.Zero),
            ("AppSpacingXxs", AppThemeTokens.Spacing.Xxs),
            ("AppSpacingXs", AppThemeTokens.Spacing.Xs),
            ("AppSpacingSm", AppThemeTokens.Spacing.Sm),
            ("AppSpacingSmMd", AppThemeTokens.Spacing.SmMd),
            ("AppSpacingMd", AppThemeTokens.Spacing.Md),
            ("AppSpacingMdLg", AppThemeTokens.Spacing.MdLg),
            ("AppSpacingLg", AppThemeTokens.Spacing.Lg),
            ("AppSpacingLgXl", AppThemeTokens.Spacing.LgXl),
            ("AppSpacingXl", AppThemeTokens.Spacing.Xl),
            ("AppSpacingXlXxl", AppThemeTokens.Spacing.XlXxl),
            ("AppSpacingXxl", AppThemeTokens.Spacing.Xxl),

            ("AppFontSizeMicro", AppThemeTokens.FontSize.Micro),
            ("AppFontSizeXxs", AppThemeTokens.FontSize.Xxs),
            ("AppFontSizeXs", AppThemeTokens.FontSize.Xs),
            ("AppFontSizeSm", AppThemeTokens.FontSize.Sm),
            ("AppFontSizeSmMd", AppThemeTokens.FontSize.SmMd),
            ("AppFontSizeMd", AppThemeTokens.FontSize.Md),
            ("AppFontSizeMdLg", AppThemeTokens.FontSize.MdLg),
            ("AppFontSizeLg", AppThemeTokens.FontSize.Lg),
            ("AppFontSizeXl", AppThemeTokens.FontSize.Xl),
            ("AppFontSizeTitle1", AppThemeTokens.FontSize.Title1),
            ("AppFontSizeTitle2", AppThemeTokens.FontSize.Title2),
            ("AppFontSizeDisplay", AppThemeTokens.FontSize.Display),

            ("AppTrackingTight", AppThemeTokens.Tracking.Tight),
            ("AppTrackingNormal", AppThemeTokens.Tracking.Normal),
            ("AppTrackingWide", AppThemeTokens.Tracking.Wide),

            ("AppIconSizeXxs", AppThemeTokens.IconSize.Xxs),
            ("AppIconSizeXs", AppThemeTokens.IconSize.Xs),
            ("AppIconSizeSm", AppThemeTokens.IconSize.Sm),
            ("AppIconSizeSmMd", AppThemeTokens.IconSize.SmMd),
            ("AppIconSizeMd", AppThemeTokens.IconSize.Md),
            ("AppIconSizeMdLg", AppThemeTokens.IconSize.MdLg),
            ("AppIconSizeLg", AppThemeTokens.IconSize.Lg),
            ("AppIconSizeLgXl", AppThemeTokens.IconSize.LgXl),
            ("AppIconSizeXl", AppThemeTokens.IconSize.Xl),

            ("AppComponentSizeCaptionPreviewMaxHeight", AppThemeTokens.ComponentSize.CaptionPreviewMaxHeight),
            ("AppComponentSizeCaptionPreviewMaxTextWidthRatio", AppThemeTokens.ComponentSize.CaptionPreviewMaxTextWidthRatio),
            ("AppComponentSizeToolImagePreviewMaxHeight", AppThemeTokens.ComponentSize.ToolImagePreviewMaxHeight),
            ("AppComponentSizeProjectCardWidth", AppThemeTokens.ComponentSize.ProjectCardWidth),
            ("AppComponentSizeProjectCardHeight", AppThemeTokens.ComponentSize.ProjectCardHeight),
            ("AppComponentSizeTimelineClipBorderMinWidth", AppThemeTokens.ComponentSize.TimelineClipBorderMinWidth),
            ("AppComponentSizeTimelineClipDetailMinWidth", AppThemeTokens.ComponentSize.TimelineClipDetailMinWidth),
            ("AppComponentSizeTimelineTabRenameWidth", AppThemeTokens.ComponentSize.TimelineTabRenameWidth),
            ("AppComponentSizeTimelineClipLabelMinWidth", AppThemeTokens.ComponentSize.TimelineClipLabelMinWidth),
            ("AppComponentSizeTimelineBadgePadH", AppThemeTokens.ComponentSize.TimelineBadgePadH),
            ("AppComponentSizeTimelineBadgePadV", AppThemeTokens.ComponentSize.TimelineBadgePadV),
            ("AppComponentSizeTimelineBadgeMinWidth", AppThemeTokens.ComponentSize.TimelineBadgeMinWidth),
            ("AppComponentSizeTimelineDotSize", AppThemeTokens.ComponentSize.TimelineDotSize),
            ("AppComponentSizeUpdateOverlayWidth", AppThemeTokens.ComponentSize.UpdateOverlayWidth),

            ("AppWindowHomeDefaultWidth", AppThemeTokens.Window.HomeDefault.Width),
            ("AppWindowHomeDefaultHeight", AppThemeTokens.Window.HomeDefault.Height),
            ("AppWindowHomeMinWidth", AppThemeTokens.Window.HomeMin.Width),
            ("AppWindowHomeMinHeight", AppThemeTokens.Window.HomeMin.Height),
            ("AppWindowProjectMinWidth", AppThemeTokens.Window.ProjectMin.Width),
            ("AppWindowProjectMinHeight", AppThemeTokens.Window.ProjectMin.Height),
            ("AppWindowProjectTitlebarTrailingWidth", AppThemeTokens.Window.ProjectTitlebarTrailingWidth),
            ("AppWindowSettingsDefaultWidth", AppThemeTokens.Window.SettingsDefault.Width),
            ("AppWindowSettingsDefaultHeight", AppThemeTokens.Window.SettingsDefault.Height),
            ("AppWindowSettingsMinWidth", AppThemeTokens.Window.SettingsMin.Width),
            ("AppWindowSettingsMinHeight", AppThemeTokens.Window.SettingsMin.Height),

            ("AppCaptionDefaultFontSize", AppThemeTokens.Caption.DefaultFontSize),
            ("AppCaptionMinFontSize", AppThemeTokens.Caption.MinFontSize),
            ("AppCaptionMaxFontSize", AppThemeTokens.Caption.MaxFontSize),
            ("AppCaptionMinPosition", AppThemeTokens.Caption.MinPosition),
            ("AppCaptionMaxPosition", AppThemeTokens.Caption.MaxPosition),
            ("AppCaptionCenterSnapValue", AppThemeTokens.Caption.CenterSnapValue),
            ("AppCaptionCenterSnapThreshold", AppThemeTokens.Caption.CenterSnapThreshold),
            ("AppCaptionDefaultCenterY", AppThemeTokens.Caption.DefaultCenterY),
            ("AppCaptionDefaultCenterX", AppThemeTokens.Caption.DefaultCenter.X),
            ("AppCaptionMinDisplayDuration", AppThemeTokens.Caption.MinDisplayDuration),

            ("AppGenerationPanelMediaAreaMinHeight", AppThemeTokens.GenerationPanel.MediaAreaMinHeight),
            ("AppGenerationPanelLoadingHeight", AppThemeTokens.GenerationPanel.LoadingHeight),
            ("AppGenerationPanelPromptMinHeight", AppThemeTokens.GenerationPanel.PromptMinHeight),
            ("AppGenerationPanelReferenceTileWidth", AppThemeTokens.GenerationPanel.ReferenceTileWidth),
            ("AppGenerationPanelReferenceTileHeight", AppThemeTokens.GenerationPanel.ReferenceTileHeight),

            ("AppMediaPanelTabRailWidth", AppThemeTokens.MediaPanel.TabRailWidth),
            ("AppMediaPanelContextRowHeight", AppThemeTokens.MediaPanel.ContextRowHeight),

            ("AppExportSheetWidth", AppThemeTokens.Export.SheetWidth),
            ("AppExportSheetHeight", AppThemeTokens.Export.SheetHeight),
            ("AppExportLogPaneWidth", AppThemeTokens.Export.LogPaneWidth),
            ("AppExportQueueTimestampWidth", AppThemeTokens.Export.QueueTimestampWidth),
            ("AppExportActivityDotSize", AppThemeTokens.Export.ActivityDotSize),
            ("AppExportQueueProgressBarWidth", AppThemeTokens.Export.QueueProgressBarWidth),
            ("AppExportQueueProgressWidth", AppThemeTokens.Export.QueueProgressWidth),
            ("AppExportSheetWidthWithLog", AppThemeTokens.Export.SheetWidthWithLog),

            ("AppMatteSheetWidth", AppThemeTokens.Matte.SheetWidth),
            ("AppMatteControlWidth", AppThemeTokens.Matte.ControlWidth),

            ("AppShadowSmRadius", AppThemeTokens.Shadow.Sm.Radius),
            ("AppShadowSmX", AppThemeTokens.Shadow.Sm.X),
            ("AppShadowSmY", AppThemeTokens.Shadow.Sm.Y),
            ("AppShadowMdRadius", AppThemeTokens.Shadow.Md.Radius),
            ("AppShadowMdX", AppThemeTokens.Shadow.Md.X),
            ("AppShadowMdY", AppThemeTokens.Shadow.Md.Y),
            ("AppShadowLgRadius", AppThemeTokens.Shadow.Lg.Radius),
            ("AppShadowLgX", AppThemeTokens.Shadow.Lg.X),
            ("AppShadowLgY", AppThemeTokens.Shadow.Lg.Y),

            ("AppAnimHover", AppThemeTokens.Anim.Hover),
            ("AppAnimTransition", AppThemeTokens.Anim.Transition),
            ("AppAnimPulse", AppThemeTokens.Anim.Pulse),
        ];
        foreach (var e in entries)
        {
            yield return [e.Key, e.Expected];
        }
    }

    [Theory]
    [MemberData(nameof(DoubleTokens))]
    public void DoubleResourceMatchesToken(string xamlKey, double expected)
    {
        var actual = ResolveDouble(xamlKey);
        actual.ShouldBe(expected, tolerance: 1e-9, customMessage: $"{xamlKey}: XAML={actual} Core={expected}");
    }

    public static IEnumerable<object[]> IntTokens()
    {
        (string Key, int Expected)[] entries =
        [
            ("AppFontWeightLight", AppThemeTokens.FontWeight.Light),
            ("AppFontWeightRegular", AppThemeTokens.FontWeight.Regular),
            ("AppFontWeightMedium", AppThemeTokens.FontWeight.Medium),
            ("AppFontWeightSemibold", AppThemeTokens.FontWeight.Semibold),
            ("AppFontWeightBold", AppThemeTokens.FontWeight.Bold),
        ];
        foreach (var e in entries)
        {
            yield return [e.Key, e.Expected];
        }
    }

    [Theory]
    [MemberData(nameof(IntTokens))]
    public void IntResourceMatchesToken(string xamlKey, int expected)
    {
        ResolveInt(xamlKey).ShouldBe(expected);
    }

    public static IEnumerable<object[]> GradientTokens()
    {
        (string Key, GradientToken Expected)[] entries =
        [
            ("AppAiGradientBrush", AppThemeTokens.AiGradient),
            ("AppAiGradientDarkBrush", AppThemeTokens.AiGradientDark),
            ("AppAccentSpotlightGradientBrush", AppThemeTokens.Accent.SpotlightGradient),
            ("AppSliderTempGradientBrush", AppThemeTokens.Slider.TempGradient),
            ("AppSliderTintGradientBrush", AppThemeTokens.Slider.TintGradient),
            ("AppSliderLumaGradientBrush", AppThemeTokens.Slider.LumaGradient),
        ];
        foreach (var e in entries)
        {
            yield return [e.Key, e.Expected];
        }
    }

    [Theory]
    [MemberData(nameof(GradientTokens))]
    public void GradientResourceMatchesToken(string xamlKey, GradientToken expected)
    {
        var actual = ResolveGradient(xamlKey);
        actual.Start.ShouldBe(expected.Start, $"{xamlKey} start point");
        actual.End.ShouldBe(expected.End, $"{xamlKey} end point");
        actual.Stops.Length.ShouldBe(expected.Stops.Length, $"{xamlKey} stop count");
        for (var i = 0; i < expected.Stops.Length; i++)
        {
            actual.Stops[i].Color.ShouldBe(expected.Stops[i].Color, $"{xamlKey} stop {i} color");
            actual.Stops[i].Location.ShouldBe(expected.Stops[i].Location, tolerance: 1e-9, customMessage: $"{xamlKey} stop {i} location");
        }
    }

    [Fact]
    public void RadiusConcentricMatchesSwiftMaxFormula()
    {
        AppThemeTokens.Radius.Concentric(10, 4).ShouldBe(6.0);
        AppThemeTokens.Radius.Concentric(4, 10).ShouldBe(0.0); // clamped — mirrors Swift's max(outer - padding, 0)
    }

    [Fact]
    public void FontFamilyIsTheDocumentedWindowsOnlyDivergence()
    {
        // The Mac AppTheme has no FontFamily token — SF Pro can't ship off Apple platforms (see
        // AppThemeTokens.FontFamily). This is the one token intentionally added, not ported.
        var el = Resources["AppFontFamily"];
        el.Value.ShouldBe($"ms-appx:///Assets/Fonts/Inter/Inter-Variable.ttf#{AppThemeTokens.FontFamily.Ui}");
    }
}
