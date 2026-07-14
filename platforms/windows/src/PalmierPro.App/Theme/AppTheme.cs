using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using PalmierPro.Core.Theme;
using Windows.Foundation;
using Windows.UI;

namespace PalmierPro.App.Theme;

/// <summary>
/// Thin WinUI adapters over <see cref="AppThemeTokens"/> — converts the WinRT-free primitives
/// into the WinUI types views actually bind against. Prefer the <c>Theme.xaml</c> StaticResources
/// in markup; reach for these from code-behind / ViewModels / Win2D drawing where a resource
/// lookup isn't available.
/// </summary>
public static class AppTheme
{
    public static Color ToColor(uint argb) =>
        Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

    public static SolidColorBrush ToBrush(uint argb) => new(ToColor(argb));

    public static Point ToPoint(ThemePoint point) => new(point.X, point.Y);

    public static LinearGradientBrush ToBrush(GradientToken gradient)
    {
        var brush = new LinearGradientBrush { StartPoint = ToPoint(gradient.Start), EndPoint = ToPoint(gradient.End) };
        foreach (var stop in gradient.Stops)
        {
            brush.GradientStops.Add(new Microsoft.UI.Xaml.Media.GradientStop { Color = ToColor(stop.Color), Offset = stop.Location });
        }
        return brush;
    }

    public static CornerRadius UniformCornerRadius(double radius) => new(radius);

    public static Thickness UniformThickness(double value) => new(value);

    public static Thickness ThicknessOf(double left, double top, double right, double bottom) => new(left, top, right, bottom);

    public static GridLength PixelGridLength(double value) => new(value, GridUnitType.Pixel);

    /// Maps the five AppThemeTokens.FontWeight numeric tokens onto Microsoft.UI.Text.FontWeights.
    public static Windows.UI.Text.FontWeight FontWeightFor(int weightToken) => weightToken switch
    {
        AppThemeTokens.FontWeight.Light => FontWeights.Light,
        AppThemeTokens.FontWeight.Regular => FontWeights.Normal,
        AppThemeTokens.FontWeight.Medium => FontWeights.Medium,
        AppThemeTokens.FontWeight.Semibold => FontWeights.SemiBold,
        AppThemeTokens.FontWeight.Bold => FontWeights.Bold,
        _ => throw new ArgumentOutOfRangeException(nameof(weightToken), weightToken, "Not one of the five AppThemeTokens.FontWeight tokens."),
    };

    /// Windows UI chrome font — see AppThemeTokens.FontFamily for why this diverges from the Mac.
    public static readonly FontFamily UiFontFamily = new($"ms-appx:///Assets/Fonts/Inter/Inter-Variable.ttf#{AppThemeTokens.FontFamily.Ui}");

    public static class Background
    {
        public static readonly Color Base = ToColor(AppThemeTokens.Background.Base);
        public static readonly SolidColorBrush BaseBrush = ToBrush(AppThemeTokens.Background.Base);
        public static readonly Color Surface = ToColor(AppThemeTokens.Background.Surface);
        public static readonly SolidColorBrush SurfaceBrush = ToBrush(AppThemeTokens.Background.Surface);
        public static readonly Color Raised = ToColor(AppThemeTokens.Background.Raised);
        public static readonly SolidColorBrush RaisedBrush = ToBrush(AppThemeTokens.Background.Raised);
        public static readonly Color Prominent = ToColor(AppThemeTokens.Background.Prominent);
        public static readonly SolidColorBrush ProminentBrush = ToBrush(AppThemeTokens.Background.Prominent);
        public static readonly Color Placeholder = ToColor(AppThemeTokens.Background.Placeholder);
        public static readonly SolidColorBrush PlaceholderBrush = ToBrush(AppThemeTokens.Background.Placeholder);
        public static readonly Color PreviewCanvas = ToColor(AppThemeTokens.Background.PreviewCanvas);
        public static readonly SolidColorBrush PreviewCanvasBrush = ToBrush(AppThemeTokens.Background.PreviewCanvas);
        public static readonly Color Clear = ToColor(AppThemeTokens.Background.Clear);
        public static readonly SolidColorBrush ClearBrush = ToBrush(AppThemeTokens.Background.Clear);
    }

    public static class Border
    {
        public static readonly Color Primary = ToColor(AppThemeTokens.Border.Primary);
        public static readonly SolidColorBrush PrimaryBrush = ToBrush(AppThemeTokens.Border.Primary);
        public static readonly Color Subtle = ToColor(AppThemeTokens.Border.Subtle);
        public static readonly SolidColorBrush SubtleBrush = ToBrush(AppThemeTokens.Border.Subtle);
        public static readonly Color Divider = ToColor(AppThemeTokens.Border.Divider);
        public static readonly SolidColorBrush DividerBrush = ToBrush(AppThemeTokens.Border.Divider);
        public static readonly Color TimelineClip = ToColor(AppThemeTokens.Border.TimelineClip);
        public static readonly SolidColorBrush TimelineClipBrush = ToBrush(AppThemeTokens.Border.TimelineClip);
    }

    public static class Accent
    {
        public static readonly Color Timecode = ToColor(AppThemeTokens.Accent.Timecode);
        public static readonly SolidColorBrush TimecodeBrush = ToBrush(AppThemeTokens.Accent.Timecode);
        public static readonly Color Primary = ToColor(AppThemeTokens.Accent.Primary);
        public static readonly SolidColorBrush PrimaryBrush = ToBrush(AppThemeTokens.Accent.Primary);
        public static readonly Color Spotlight = ToColor(AppThemeTokens.Accent.Spotlight);
        public static readonly SolidColorBrush SpotlightBrush = ToBrush(AppThemeTokens.Accent.Spotlight);
        public static readonly LinearGradientBrush SpotlightGradientBrush = ToBrush(AppThemeTokens.Accent.SpotlightGradient);
    }

    public static class Update
    {
        public static readonly Color Accent = ToColor(AppThemeTokens.Update.Accent);
        public static readonly SolidColorBrush AccentBrush = ToBrush(AppThemeTokens.Update.Accent);
    }

    public static class Slider
    {
        public static readonly LinearGradientBrush TempGradientBrush = ToBrush(AppThemeTokens.Slider.TempGradient);
        public static readonly LinearGradientBrush TintGradientBrush = ToBrush(AppThemeTokens.Slider.TintGradient);
        public static readonly LinearGradientBrush LumaGradientBrush = ToBrush(AppThemeTokens.Slider.LumaGradient);
    }

    public static class AudioMeter
    {
        public static readonly Color GreenSegment = ToColor(AppThemeTokens.AudioMeter.GreenSegment);
        public static readonly SolidColorBrush GreenSegmentBrush = ToBrush(AppThemeTokens.AudioMeter.GreenSegment);
        public static readonly Color YellowSegment = ToColor(AppThemeTokens.AudioMeter.YellowSegment);
        public static readonly SolidColorBrush YellowSegmentBrush = ToBrush(AppThemeTokens.AudioMeter.YellowSegment);
        public static readonly Color RedSegment = ToColor(AppThemeTokens.AudioMeter.RedSegment);
        public static readonly SolidColorBrush RedSegmentBrush = ToBrush(AppThemeTokens.AudioMeter.RedSegment);
    }

    public static class Wheels
    {
        public static readonly Color CrosshairColor = ToColor(AppThemeTokens.Wheels.CrosshairColor);
        public static readonly SolidColorBrush CrosshairColorBrush = ToBrush(AppThemeTokens.Wheels.CrosshairColor);
    }

    public static class Curve
    {
        public static readonly Color LumaColor = ToColor(AppThemeTokens.Curve.LumaColor);
        public static readonly SolidColorBrush LumaColorBrush = ToBrush(AppThemeTokens.Curve.LumaColor);
        public static readonly Color RedColor = ToColor(AppThemeTokens.Curve.RedColor);
        public static readonly SolidColorBrush RedColorBrush = ToBrush(AppThemeTokens.Curve.RedColor);
        public static readonly Color GreenColor = ToColor(AppThemeTokens.Curve.GreenColor);
        public static readonly SolidColorBrush GreenColorBrush = ToBrush(AppThemeTokens.Curve.GreenColor);
        public static readonly Color BlueColor = ToColor(AppThemeTokens.Curve.BlueColor);
        public static readonly SolidColorBrush BlueColorBrush = ToBrush(AppThemeTokens.Curve.BlueColor);
    }

    public static readonly LinearGradientBrush AiGradientBrush = ToBrush(AppThemeTokens.AiGradient);
    public static readonly LinearGradientBrush AiGradientDarkBrush = ToBrush(AppThemeTokens.AiGradientDark);

    public static class Glass
    {
        public static readonly Color PrimaryTint = ToColor(AppThemeTokens.Glass.PrimaryTint);
        public static readonly SolidColorBrush PrimaryTintBrush = ToBrush(AppThemeTokens.Glass.PrimaryTint);
    }

    public static class Status
    {
        public static readonly Color Error = ToColor(AppThemeTokens.Status.Error);
        public static readonly SolidColorBrush ErrorBrush = ToBrush(AppThemeTokens.Status.Error);
        public static readonly Color Success = ToColor(AppThemeTokens.Status.Success);
        public static readonly SolidColorBrush SuccessBrush = ToBrush(AppThemeTokens.Status.Success);
        public static readonly Color Warning = ToColor(AppThemeTokens.Status.Warning);
        public static readonly SolidColorBrush WarningBrush = ToBrush(AppThemeTokens.Status.Warning);
    }

    public static class Text
    {
        public static readonly Color Primary = ToColor(AppThemeTokens.Text.Primary);
        public static readonly SolidColorBrush PrimaryBrush = ToBrush(AppThemeTokens.Text.Primary);
        public static readonly Color Secondary = ToColor(AppThemeTokens.Text.Secondary);
        public static readonly SolidColorBrush SecondaryBrush = ToBrush(AppThemeTokens.Text.Secondary);
        public static readonly Color Tertiary = ToColor(AppThemeTokens.Text.Tertiary);
        public static readonly SolidColorBrush TertiaryBrush = ToBrush(AppThemeTokens.Text.Tertiary);
        public static readonly Color Muted = ToColor(AppThemeTokens.Text.Muted);
        public static readonly SolidColorBrush MutedBrush = ToBrush(AppThemeTokens.Text.Muted);
    }

    public static class TrackColor
    {
        public static readonly Color Video = ToColor(AppThemeTokens.TrackColor.Video);
        public static readonly SolidColorBrush VideoBrush = ToBrush(AppThemeTokens.TrackColor.Video);
        public static readonly Color Audio = ToColor(AppThemeTokens.TrackColor.Audio);
        public static readonly SolidColorBrush AudioBrush = ToBrush(AppThemeTokens.TrackColor.Audio);
        public static readonly Color Image = ToColor(AppThemeTokens.TrackColor.Image);
        public static readonly SolidColorBrush ImageBrush = ToBrush(AppThemeTokens.TrackColor.Image);
        public static readonly Color Text = ToColor(AppThemeTokens.TrackColor.Text);
        public static readonly SolidColorBrush TextBrush = ToBrush(AppThemeTokens.TrackColor.Text);
        public static readonly Color Lottie = ToColor(AppThemeTokens.TrackColor.Lottie);
        public static readonly SolidColorBrush LottieBrush = ToBrush(AppThemeTokens.TrackColor.Lottie);
        public static readonly Color Sequence = ToColor(AppThemeTokens.TrackColor.Sequence);
        public static readonly SolidColorBrush SequenceBrush = ToBrush(AppThemeTokens.TrackColor.Sequence);
        public static readonly Color Multicam = ToColor(AppThemeTokens.TrackColor.Multicam);
        public static readonly SolidColorBrush MulticamBrush = ToBrush(AppThemeTokens.TrackColor.Multicam);
    }

    public static class Shadow
    {
        public static readonly Color Sm = ToColor(AppThemeTokens.Shadow.Sm.Color);
        public static readonly Color Md = ToColor(AppThemeTokens.Shadow.Md.Color);
        public static readonly Color Lg = ToColor(AppThemeTokens.Shadow.Lg.Color);
    }
}
