using PalmierPro.Core;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// Not Codable in Swift — `MatteAspect` round-trips as a plain string via `.rawValue`/`.parse`.
/// Only the pure-math half of Matte.swift is ported here: image generation (`Matte.png`,
/// `Color.matteHex`) is a rendering-layer concern (AppKit `CGContext` on the Mac) with no Core
/// analog yet — Win2D/Direct2D solid-color fill is a straightforward equivalent when the
/// rendering layer lands, not a domain-model concern.
public enum MatteAspect
{
    [SwiftRawValue("Project")] Project,
    [SwiftRawValue("16:9")] SixteenNine,
    [SwiftRawValue("9:16")] NineSixteen,
    [SwiftRawValue("1:1")] OneOne,
    [SwiftRawValue("4:3")] FourThree,
    [SwiftRawValue("9:14")] NineFourteen,
    [SwiftRawValue("2.4:1")] TwoPointFourToOne,
}

public static class MatteAspectExtensions
{
    public static string RawValue(this MatteAspect aspect) => SwiftStringEnumConverter<MatteAspect>.RawValue(aspect);

    private static (int W, int H)? Ratio(this MatteAspect aspect) => aspect switch
    {
        MatteAspect.Project => null,
        MatteAspect.SixteenNine => (16, 9),
        MatteAspect.NineSixteen => (9, 16),
        MatteAspect.OneOne => (1, 1),
        MatteAspect.FourThree => (4, 3),
        MatteAspect.NineFourteen => (9, 14),
        MatteAspect.TwoPointFourToOne => (24, 10),
        _ => throw new ArgumentOutOfRangeException(nameof(aspect)),
    };

    public static (int Width, int Height) PixelSize(this MatteAspect aspect, int timelineWidth, int timelineHeight)
    {
        var ratio = aspect.Ratio();
        if (ratio is not { } r)
        {
            return Matte.Even(timelineWidth, timelineHeight);
        }
        return Matte.Fit(Math.Min(timelineWidth, timelineHeight), r.W, r.H);
    }

    /// Mirrors `MatteAspect.parse(_:)`: trims whitespace, "project" is case-insensitive,
    /// everything else is a case-sensitive raw-value lookup.
    public static MatteAspect? Parse(string? raw)
    {
        var trimmed = raw?.Trim();
        if (string.IsNullOrEmpty(trimmed))
        {
            return null;
        }
        if (string.Equals(trimmed, "project", StringComparison.OrdinalIgnoreCase))
        {
            return MatteAspect.Project;
        }
        return SwiftStringEnumConverter<MatteAspect>.TryParse(trimmed, out var value) ? value : null;
    }
}

public static class Matte
{
    public static (int Width, int Height) Even(int w, int h) =>
        (Math.Max(2, Math.Max(2, w) / 2 * 2), Math.Max(2, Math.Max(2, h) / 2 * 2));

    public static (int Width, int Height) Fit(int shortEdge, int aspectW, int aspectH)
    {
        var e = Math.Max(2, shortEdge);
        double aw = aspectW, ah = aspectH;
        if (aw >= ah)
        {
            return Even(SwiftMath.RoundToInt(e * aw / ah), e);
        }
        return Even(e, SwiftMath.RoundToInt(e * ah / aw));
    }
}
