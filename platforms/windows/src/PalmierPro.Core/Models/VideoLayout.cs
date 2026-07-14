using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// None of the types in this file are Swift `Codable` — VideoLayout is round-tripped through
/// `ProjectFile.multicamGroups` as a plain string and parsed manually via `rawValue:`, which is
/// why the raw-value plumbing exists here without a `[JsonConverter]` registration.

public readonly record struct LayoutRect(double X, double Y, double W, double H);

public readonly record struct LayoutSlot(string Id, LayoutRect Rect, int Z = 0);

public enum LayoutFit
{
    [SwiftRawValue("fill")] Fill,
    [SwiftRawValue("fit")] Fit,
}

public enum VideoLayout
{
    [SwiftRawValue("full")] Full,
    [SwiftRawValue("side_by_side")] SideBySide,
    [SwiftRawValue("top_bottom")] TopBottom,
    [SwiftRawValue("pip_bottom_right")] PipBottomRight,
    [SwiftRawValue("pip_bottom_left")] PipBottomLeft,
    [SwiftRawValue("pip_top_right")] PipTopRight,
    [SwiftRawValue("pip_top_left")] PipTopLeft,
    [SwiftRawValue("grid_2x2")] Grid2x2,
    [SwiftRawValue("main_sidebar")] MainSidebar,
    [SwiftRawValue("three_up")] ThreeUp,
}

public static class VideoLayoutExtensions
{
    private const double PipInset = 0.28;
    private const double PipMargin = 0.035;

    public static string RawValue(this VideoLayout layout) => SwiftStringEnumConverter<VideoLayout>.RawValue(layout);

    public static bool TryParse(string raw, out VideoLayout layout) =>
        SwiftStringEnumConverter<VideoLayout>.TryParse(raw, out layout);

    public static string DisplayName(this VideoLayout layout) => layout switch
    {
        VideoLayout.Full => "Full Frame",
        VideoLayout.SideBySide => "Side by Side",
        VideoLayout.TopBottom => "Top / Bottom",
        VideoLayout.PipBottomRight => "PiP Bottom Right",
        VideoLayout.PipBottomLeft => "PiP Bottom Left",
        VideoLayout.PipTopRight => "PiP Top Right",
        VideoLayout.PipTopLeft => "PiP Top Left",
        VideoLayout.Grid2x2 => "Grid 2×2",
        VideoLayout.MainSidebar => "Main + Sidebar",
        VideoLayout.ThreeUp => "Three-Up",
        _ => throw new ArgumentOutOfRangeException(nameof(layout)),
    };

    public static List<LayoutSlot> Slots(this VideoLayout layout) => layout switch
    {
        VideoLayout.Full =>
        [
            new LayoutSlot("main", new LayoutRect(0, 0, 1, 1)),
        ],

        VideoLayout.SideBySide =>
        [
            new LayoutSlot("left", new LayoutRect(0, 0, 0.5, 1)),
            new LayoutSlot("right", new LayoutRect(0.5, 0, 0.5, 1)),
        ],

        VideoLayout.TopBottom =>
        [
            new LayoutSlot("top", new LayoutRect(0, 0, 1, 0.5)),
            new LayoutSlot("bottom", new LayoutRect(0, 0.5, 1, 0.5)),
        ],

        VideoLayout.PipBottomRight => Pip(1 - PipMargin - PipInset, 1 - PipMargin - PipInset),
        VideoLayout.PipBottomLeft => Pip(PipMargin, 1 - PipMargin - PipInset),
        VideoLayout.PipTopRight => Pip(1 - PipMargin - PipInset, PipMargin),
        VideoLayout.PipTopLeft => Pip(PipMargin, PipMargin),

        VideoLayout.Grid2x2 =>
        [
            new LayoutSlot("top_left", new LayoutRect(0, 0, 0.5, 0.5)),
            new LayoutSlot("top_right", new LayoutRect(0.5, 0, 0.5, 0.5)),
            new LayoutSlot("bottom_left", new LayoutRect(0, 0.5, 0.5, 0.5)),
            new LayoutSlot("bottom_right", new LayoutRect(0.5, 0.5, 0.5, 0.5)),
        ],

        VideoLayout.MainSidebar =>
        [
            new LayoutSlot("main", new LayoutRect(0, 0, 0.7, 1)),
            new LayoutSlot("sidebar", new LayoutRect(0.7, 0, 0.3, 1)),
        ],

        VideoLayout.ThreeUp => ThreeUpSlots(),

        _ => throw new ArgumentOutOfRangeException(nameof(layout)),
    };

    private static List<LayoutSlot> ThreeUpSlots()
    {
        const double third = 1.0 / 3.0;
        return
        [
            new LayoutSlot("left", new LayoutRect(0, 0, third, 1)),
            new LayoutSlot("center", new LayoutRect(third, 0, third, 1)),
            new LayoutSlot("right", new LayoutRect(third * 2, 0, third, 1)),
        ];
    }

    private static List<LayoutSlot> Pip(double insetX, double insetY) =>
    [
        new LayoutSlot("main", new LayoutRect(0, 0, 1, 1), Z: 0),
        new LayoutSlot("inset", new LayoutRect(insetX, insetY, PipInset, PipInset), Z: 1),
    ];
}
