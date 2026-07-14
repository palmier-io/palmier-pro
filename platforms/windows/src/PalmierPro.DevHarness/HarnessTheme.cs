using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using PalmierPro.Core.Theme;
using Windows.UI;

namespace PalmierPro.DevHarness;

// Thin WinUI adapter over AppThemeTokens, scoped to what the harness toolbar needs.
// Mirrors PalmierPro.App/Theme/AppTheme.cs's conversion helpers rather than
// referencing that project directly — DevHarness intentionally stays a leaf tool with
// no dependency on the App executable (see AGENTS.md: AppThemeTokens is the source of
// truth both adapters read from).
internal static class HarnessTheme
{
    private static Color ToColor(uint argb) =>
        Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

    private static SolidColorBrush ToBrush(uint argb) => new(ToColor(argb));

    internal static readonly SolidColorBrush BackgroundBaseBrush = ToBrush(AppThemeTokens.Background.Base);
    internal static readonly SolidColorBrush BackgroundSurfaceBrush = ToBrush(AppThemeTokens.Background.Surface);
    internal static readonly SolidColorBrush BorderPrimaryBrush = ToBrush(AppThemeTokens.Border.Primary);
    internal static readonly SolidColorBrush TextPrimaryBrush = ToBrush(AppThemeTokens.Text.Primary);
    internal static readonly SolidColorBrush TextSecondaryBrush = ToBrush(AppThemeTokens.Text.Secondary);
    internal static readonly SolidColorBrush TextMutedBrush = ToBrush(AppThemeTokens.Text.Muted);
    internal static readonly SolidColorBrush StatusErrorBrush = ToBrush(AppThemeTokens.Status.Error);

    internal static Thickness UniformThickness(double value) => new(value);
    internal static Thickness ThicknessOf(double left, double top, double right, double bottom) => new(left, top, right, bottom);
    internal static CornerRadius UniformCornerRadius(double radius) => new(radius);
}
