using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

public class VideoLayoutTests
{
    [Fact]
    public void RawValueUsesSnakeCaseForMultiWordLayouts()
    {
        VideoLayout.SideBySide.RawValue().ShouldBe("side_by_side");
        VideoLayout.Grid2x2.RawValue().ShouldBe("grid_2x2");
    }

    [Fact]
    public void TryParseRoundTripsEveryRawValue()
    {
        foreach (var layout in Enum.GetValues<VideoLayout>())
        {
            VideoLayoutExtensions.TryParse(layout.RawValue(), out var parsed).ShouldBeTrue();
            parsed.ShouldBe(layout);
        }
    }

    [Fact]
    public void TryParseRejectsUnknownRawValue()
    {
        VideoLayoutExtensions.TryParse("not_a_layout", out _).ShouldBeFalse();
    }

    [Fact]
    public void FullLayoutHasSingleFullFrameSlot()
    {
        var slots = VideoLayout.Full.Slots();
        slots.Count.ShouldBe(1);
        slots[0].Rect.W.ShouldBe(1);
        slots[0].Rect.H.ShouldBe(1);
    }

    [Fact]
    public void SideBySideSplitsCanvasInHalf()
    {
        var slots = VideoLayout.SideBySide.Slots();
        slots.Count.ShouldBe(2);
        slots.Sum(s => s.Rect.W).ShouldBe(1.0);
        slots.ShouldAllBe(s => s.Rect.H == 1);
    }

    [Fact]
    public void Grid2x2HasFourEqualQuadrants()
    {
        var slots = VideoLayout.Grid2x2.Slots();
        slots.Count.ShouldBe(4);
        slots.ShouldAllBe(s => s.Rect.W == 0.5 && s.Rect.H == 0.5);
    }

    [Fact]
    public void PipLayoutsPlaceInsetAboveMain()
    {
        var slots = VideoLayout.PipBottomRight.Slots();
        slots.Count.ShouldBe(2);
        slots.Single(s => s.Id == "main").Z.ShouldBe(0);
        slots.Single(s => s.Id == "inset").Z.ShouldBe(1);
    }

    [Fact]
    public void ThreeUpSplitsCanvasInThirds()
    {
        var slots = VideoLayout.ThreeUp.Slots();
        slots.Count.ShouldBe(3);
        Math.Abs(slots.Sum(s => s.Rect.W) - 1.0).ShouldBeLessThan(1e-9);
    }
}

public class MatteTests
{
    [Fact]
    public void EvenRoundsDimensionsDownToMultipleOfTwo()
    {
        var (w, h) = Matte.Even(1921, 1079);
        w.ShouldBe(1920);
        h.ShouldBe(1078);
    }

    [Fact]
    public void EvenFloorsAtTwo()
    {
        var (w, h) = Matte.Even(1, 0);
        w.ShouldBe(2);
        h.ShouldBe(2);
    }

    [Fact]
    public void FitPreservesShortEdgeForWideAspect()
    {
        var (w, h) = Matte.Fit(1080, 16, 9);
        h.ShouldBe(1080);
        w.ShouldBe(1920);
    }

    [Fact]
    public void FitPreservesShortEdgeForTallAspect()
    {
        var (w, h) = Matte.Fit(1080, 9, 16);
        w.ShouldBe(1080);
        h.ShouldBe(1920);
    }

    [Fact]
    public void PixelSizeForProjectAspectUsesTimelineDimensionsEvened()
    {
        var (w, h) = MatteAspect.Project.PixelSize(1921, 1081);
        w.ShouldBe(1920);
        h.ShouldBe(1080);
    }

    [Fact]
    public void PixelSizeForNamedAspectFitsShortEdge()
    {
        var (w, h) = MatteAspect.NineSixteen.PixelSize(1920, 1080);
        // short edge = 1080, aspect 9:16 (tall) -> width=1080, height = 1080*16/9 = 1920.
        w.ShouldBe(1080);
        h.ShouldBe(1920);
    }

    [Theory]
    [InlineData("project", true)]
    [InlineData("PROJECT", true)]
    [InlineData("  16:9 ", false)] // whitespace-trimmed but case-sensitive raw lookup after that
    [InlineData("16:9", false)]
    public void ParseHandlesProjectCaseInsensitively(string raw, bool expectProject)
    {
        var parsed = MatteAspectExtensions.Parse(raw);
        if (expectProject)
        {
            parsed.ShouldBe(MatteAspect.Project);
        }
        else
        {
            parsed.ShouldBe(MatteAspect.SixteenNine);
        }
    }

    [Fact]
    public void ParseReturnsNullForEmptyOrUnknown()
    {
        MatteAspectExtensions.Parse(null).ShouldBeNull();
        MatteAspectExtensions.Parse("   ").ShouldBeNull();
        MatteAspectExtensions.Parse("not-a-ratio").ShouldBeNull();
    }
}
