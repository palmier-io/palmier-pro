namespace PalmierPro.Core.Models;

public record struct LayoutRect(double X, double Y, double W, double H);

public record struct LayoutSlot(string Id, LayoutRect Rect, int Z = 0);

public enum LayoutFit
{
    Fill,
    Fit,
}

public enum VideoLayout
{
    Full,
    SideBySide,
    TopBottom,
    PipBottomRight,
    PipBottomLeft,
    PipTopRight,
    PipTopLeft,
    Grid2x2,
    Grid3x3,
    Grid4x4,
    MainSidebar,
    ThreeUp,
}

public static class VideoLayoutExtensions
{
    private const double PipInset = 0.28;
    private const double PipMargin = 0.035;

    /// <summary>Stable machine-facing value matching the Swift raw values (Agent contract).</summary>
    public static string RawValue(this VideoLayout layout) => layout switch
    {
        VideoLayout.Full => "full",
        VideoLayout.SideBySide => "side_by_side",
        VideoLayout.TopBottom => "top_bottom",
        VideoLayout.PipBottomRight => "pip_bottom_right",
        VideoLayout.PipBottomLeft => "pip_bottom_left",
        VideoLayout.PipTopRight => "pip_top_right",
        VideoLayout.PipTopLeft => "pip_top_left",
        VideoLayout.Grid2x2 => "grid_2x2",
        VideoLayout.Grid3x3 => "grid_3x3",
        VideoLayout.Grid4x4 => "grid_4x4",
        VideoLayout.MainSidebar => "main_sidebar",
        VideoLayout.ThreeUp => "three_up",
        _ => "full",
    };

    public static VideoLayout? FromRawValue(string raw)
    {
        foreach (var layout in Enum.GetValues<VideoLayout>())
        {
            if (layout.RawValue() == raw) return layout;
        }
        return null;
    }

    public static IReadOnlyList<LayoutSlot> Slots(this VideoLayout layout) => layout switch
    {
        VideoLayout.Full => [new LayoutSlot("main", new LayoutRect(0, 0, 1, 1))],
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
        VideoLayout.Grid2x2 => Grid(2, 2),
        VideoLayout.Grid3x3 => Grid(3, 3),
        VideoLayout.Grid4x4 => Grid(4, 4),
        VideoLayout.MainSidebar =>
        [
            new LayoutSlot("main", new LayoutRect(0, 0, 0.7, 1)),
            new LayoutSlot("sidebar", new LayoutRect(0.7, 0, 0.3, 1)),
        ],
        VideoLayout.ThreeUp =>
        [
            new LayoutSlot("left", new LayoutRect(0, 0, 1.0 / 3, 1)),
            new LayoutSlot("center", new LayoutRect(1.0 / 3, 0, 1.0 / 3, 1)),
            new LayoutSlot("right", new LayoutRect(2.0 / 3, 0, 1.0 / 3, 1)),
        ],
        _ => [new LayoutSlot("main", new LayoutRect(0, 0, 1, 1))],
    };

    private static LayoutSlot[] Grid(int rows, int columns)
    {
        var width = 1.0 / columns;
        var height = 1.0 / rows;
        return Enumerable.Range(0, rows)
            .SelectMany(row => Enumerable.Range(0, columns).Select(column =>
                new LayoutSlot($"r{row + 1}c{column + 1}", new LayoutRect(column * width, row * height, width, height))))
            .ToArray();
    }

    private static LayoutSlot[] Pip(double insetX, double insetY) =>
    [
        new LayoutSlot("main", new LayoutRect(0, 0, 1, 1)),
        new LayoutSlot("inset", new LayoutRect(insetX, insetY, PipInset, PipInset), 1),
    ];
}
