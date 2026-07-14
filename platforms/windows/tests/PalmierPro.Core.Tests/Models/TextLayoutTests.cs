using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors TextLayout.swift's pure math — glyph measurement itself goes through
/// <see cref="ITextBoundsMeasurer"/> (see its doc comment), so these tests use a stub measurer
/// and assert the surrounding canvasScale/padding/slack arithmetic exactly.
public class TextLayoutTests
{
    /// Records the (text, style, renderFontSize, maxWidth) it was called with and returns a
    /// caller-supplied bounding size, standing in for the real DirectWrite measurement.
    private sealed class StubMeasurer(double width, double height) : ITextBoundsMeasurer
    {
        public string? LastText;
        public double LastRenderFontSize;
        public double LastMaxWidth;

        public (double Width, double Height) MeasureBoundingRect(string text, TextStyle style, double renderFontSize, double maxWidth)
        {
            LastText = text;
            LastRenderFontSize = renderFontSize;
            LastMaxWidth = maxWidth;
            return (width, height);
        }
    }

    [Fact]
    public void RenderFontSizeScalesByCanvasHeightAndFontScale()
    {
        var style = new TextStyle { FontSize = 96, FontScale = 1.0 };
        var measurer = new StubMeasurer(100, 20);
        // canvasScale = canvasHeight / 1080; renderSize = fontSize * fontScale * canvasScale.
        TextLayout.NaturalSize("Hi", style, maxWidth: 500, canvasHeight: 540, measurer);
        measurer.LastRenderFontSize.ShouldBe(96 * 1.0 * 0.5);
    }

    [Fact]
    public void FontScaleMultipliesRenderFontSize()
    {
        var style = new TextStyle { FontSize = 100, FontScale = 2.0 };
        var measurer = new StubMeasurer(1, 1);
        TextLayout.NaturalSize("Hi", style, maxWidth: 500, canvasHeight: 1080, measurer);
        measurer.LastRenderFontSize.ShouldBe(200);
    }

    [Fact]
    public void EmptyContentMeasuresASingleSpace()
    {
        var measurer = new StubMeasurer(1, 1);
        TextLayout.NaturalSize("", new TextStyle(), maxWidth: 500, canvasHeight: 1080, measurer);
        measurer.LastText.ShouldBe(" ");
    }

    [Fact]
    public void MaxWidthIsForwardedUnchanged()
    {
        var measurer = new StubMeasurer(1, 1);
        TextLayout.NaturalSize("Hello", new TextStyle(), maxWidth: 321, canvasHeight: 1080, measurer);
        measurer.LastMaxWidth.ShouldBe(321);
    }

    [Fact]
    public void SizeAddsFourPixelSlackWithNoShadowOrBorder()
    {
        var style = new TextStyle { Shadow = new TextStyleShadow { Enabled = false }, Border = new TextStyleFill(false, new TextStyleRgba()) };
        var measurer = new StubMeasurer(100, 40);
        var size = TextLayout.NaturalSize("Hi", style, maxWidth: 500, canvasHeight: 1080, measurer);
        size.Width.ShouldBe(104); // ceil(100) + 0 + 0 + 4
        size.Height.ShouldBe(44); // ceil(40) + 0 + 4
    }

    [Fact]
    public void ShadowEnabledAddsDoubleShadowPaddingToWidthOnly()
    {
        var style = new TextStyle
        {
            Shadow = new TextStyleShadow { Enabled = true },
            Border = new TextStyleFill(false, new TextStyleRgba()),
        };
        var measurer = new StubMeasurer(100, 40);
        var size = TextLayout.NaturalSize("Hi", style, maxWidth: 500, canvasHeight: 1080, measurer);
        // shadowPad = 12 * 2 = 24, added to width only (not height).
        size.Width.ShouldBe(100 + 24 + 4);
        size.Height.ShouldBe(40 + 4);
    }

    [Fact]
    public void BorderEnabledAddsDoubleGlyphBorderPaddingToBothDimensions()
    {
        var renderFontSize = 96.0; // FontSize(96) * FontScale(1) * canvasScale(1080/1080 = 1)
        var style = new TextStyle
        {
            Shadow = new TextStyleShadow { Enabled = false },
            Border = new TextStyleFill(true, new TextStyleRgba()),
        };
        var measurer = new StubMeasurer(100, 40);
        var size = TextLayout.NaturalSize("Hi", style, maxWidth: 500, canvasHeight: 1080, measurer);
        var borderPad = TextStyle.GlyphBorderPadding(renderFontSize) * 2;
        size.Width.ShouldBe(100 + borderPad + 4);
        size.Height.ShouldBe(40 + borderPad + 4);
    }

    [Fact]
    public void ResultNeverGoesBelowOnePixel()
    {
        var style = new TextStyle { Shadow = new TextStyleShadow { Enabled = false }, Border = new TextStyleFill(false, new TextStyleRgba()) };
        var measurer = new StubMeasurer(-50, -50); // pathological measurer input
        var size = TextLayout.NaturalSize("Hi", style, maxWidth: 500, canvasHeight: 1080, measurer);
        size.Width.ShouldBe(1);
        size.Height.ShouldBe(1);
    }
}
