namespace PalmierPro.Core.Models;

/// Canvas aspect-ratio presets for the empty-inspector "Aspect Ratio" menu. Ported verbatim from
/// Inspector/ProjectSettingsPresets.swift's `AspectPreset` — label/width/height only, no engine
/// dependency; the Windows inspector applies these through
/// TimelineEditorViewModel.ApplyTimelineSettings, mirroring the Mac's `aspectMenuItems` calling
/// `editor.applyTimelineSettings`.
public enum AspectPreset
{
    SixteenNine,
    NineByFourteen,
    NineSixteen,
    OneOne,
    FourThree,
    TwoPointFourOne,
}

public static class AspectPresetExtensions
{
    public static readonly IReadOnlyList<AspectPreset> All =
    [
        AspectPreset.SixteenNine, AspectPreset.NineByFourteen, AspectPreset.NineSixteen,
        AspectPreset.OneOne, AspectPreset.FourThree, AspectPreset.TwoPointFourOne,
    ];

    public static string Label(this AspectPreset preset) => preset switch
    {
        AspectPreset.SixteenNine => "16:9",
        AspectPreset.NineByFourteen => "9:14",
        AspectPreset.NineSixteen => "9:16",
        AspectPreset.OneOne => "1:1",
        AspectPreset.FourThree => "4:3",
        AspectPreset.TwoPointFourOne => "2.4:1",
        _ => throw new ArgumentOutOfRangeException(nameof(preset)),
    };

    public static int Width(this AspectPreset preset) => preset switch
    {
        AspectPreset.SixteenNine => 1920,
        AspectPreset.NineByFourteen => 1080,
        AspectPreset.NineSixteen => 1080,
        AspectPreset.OneOne => 1080,
        AspectPreset.FourThree => 1440,
        AspectPreset.TwoPointFourOne => 2560,
        _ => throw new ArgumentOutOfRangeException(nameof(preset)),
    };

    public static int Height(this AspectPreset preset) => preset switch
    {
        AspectPreset.SixteenNine => 1080,
        AspectPreset.NineByFourteen => 1680,
        AspectPreset.NineSixteen => 1920,
        AspectPreset.OneOne => 1080,
        AspectPreset.FourThree => 1080,
        AspectPreset.TwoPointFourOne => 1080,
        _ => throw new ArgumentOutOfRangeException(nameof(preset)),
    };
}

/// Resolution-quality presets for the empty-inspector "Resolution" menu. Ported verbatim from
/// Inspector/ProjectSettingsPresets.swift's `QualityPreset` — scales the canvas's short edge while
/// preserving its current aspect ratio.
public enum QualityPreset
{
    Hd720,
    FullHd,
    TwoK,
    FourK,
}

public static class QualityPresetExtensions
{
    public static readonly IReadOnlyList<QualityPreset> All =
        [QualityPreset.Hd720, QualityPreset.FullHd, QualityPreset.TwoK, QualityPreset.FourK];

    public static string Label(this QualityPreset preset) => preset switch
    {
        QualityPreset.Hd720 => "720p",
        QualityPreset.FullHd => "1080p",
        QualityPreset.TwoK => "2K",
        QualityPreset.FourK => "4K",
        _ => throw new ArgumentOutOfRangeException(nameof(preset)),
    };

    /// Scale resolution while preserving the current aspect ratio. Truncates like Swift's
    /// `Int(_:)` — not SwiftMath.RoundToInt, matching the Mac source exactly.
    public static (int Width, int Height) Resolution(this QualityPreset preset, int currentWidth, int currentHeight)
    {
        var target = ShortEdge(preset);
        if (currentWidth <= 0 || currentHeight <= 0)
        {
            return (target, target);
        }
        return currentWidth <= currentHeight
            ? (target, (int)(target * (double)currentHeight / currentWidth))
            : ((int)(target * (double)currentWidth / currentHeight), target);
    }

    public static bool Matches(this QualityPreset preset, int width, int height) =>
        Math.Min(width, height) == ShortEdge(preset);

    private static int ShortEdge(QualityPreset preset) => preset switch
    {
        QualityPreset.Hd720 => 720,
        QualityPreset.FullHd => 1080,
        QualityPreset.TwoK => 1440,
        QualityPreset.FourK => 2160,
        _ => throw new ArgumentOutOfRangeException(nameof(preset)),
    };
}
