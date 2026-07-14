using System.Text.Json;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors the model half of Tests/PalmierProTests/Media/ProjectRoundTripTests.swift's TextStyle
/// coverage and Tests/PalmierProTests/Rendering/RGBAHexTests.swift.
public class TextStyleTests
{
    [Fact]
    public void DefaultsMatchSwiftMemberwiseInit()
    {
        var style = new TextStyle();
        style.FontName.ShouldBe("Helvetica-Bold");
        style.FontSize.ShouldBe(96);
        style.FontScale.ShouldBe(1.0);
        style.IsBold.ShouldBeTrue();
        style.IsItalic.ShouldBeFalse();
        style.Color.R.ShouldBe(1);
        style.Color.A.ShouldBe(1);
        style.Alignment.ShouldBe(TextStyleAlignment.Center);
        style.Shadow.Enabled.ShouldBeTrue();
        style.Shadow.OffsetY.ShouldBe(-2);
        style.Shadow.Blur.ShouldBe(6);
        style.Background.Enabled.ShouldBeFalse();
        style.Background.Color.A.ShouldBe(0.6);
        style.Border.Enabled.ShouldBeFalse();
        style.Border.Color.A.ShouldBe(1);
    }

    [Fact]
    public void FullObjectRoundTripsThroughJson()
    {
        var style = new TextStyle
        {
            FontName = "Avenir-Heavy",
            FontSize = 48,
            FontScale = 1.2,
            IsBold = false,
            IsItalic = true,
            Color = new TextStyleRgba(1, 0, 0, 1),
            Alignment = TextStyleAlignment.Right,
            Shadow = new TextStyleShadow { Enabled = false, OffsetX = 1, OffsetY = 3, Blur = 10 },
            Background = new TextStyleFill(true, new TextStyleRgba(0, 1, 0, 0.5)),
            Border = new TextStyleFill(true, new TextStyleRgba(0, 0, 1, 1)),
        };
        var json = JsonSerializer.Serialize(style);
        var decoded = JsonSerializer.Deserialize<TextStyle>(json)!;

        decoded.FontName.ShouldBe("Avenir-Heavy");
        decoded.FontScale.ShouldBe(1.2);
        decoded.IsBold.ShouldBeFalse();
        decoded.IsItalic.ShouldBeTrue();
        decoded.Color.R.ShouldBe(1);
        decoded.Alignment.ShouldBe(TextStyleAlignment.Right);
        decoded.Shadow.Enabled.ShouldBeFalse();
        decoded.Shadow.Blur.ShouldBe(10);
        decoded.Background.Enabled.ShouldBeTrue();
        decoded.Background.Color.G.ShouldBe(1);
        decoded.Border.Color.B.ShouldBe(1);
    }

    [Fact]
    public void MissingFontScaleDefaultsToOne()
    {
        // Mirrors the Swift fixture: fontScale was added later, older files omit it.
        const string json = """
        {
          "fontName": "Helvetica-Bold",
          "fontSize": 96,
          "color": {"r": 1, "g": 1, "b": 1, "a": 1},
          "alignment": "center",
          "shadow": {
            "enabled": true,
            "color": {"r": 0, "g": 0, "b": 0, "a": 0.6},
            "offsetX": 0, "offsetY": -2, "blur": 6
          }
        }
        """;
        var style = JsonSerializer.Deserialize<TextStyle>(json)!;
        style.FontScale.ShouldBe(1.0);
    }

    [Fact]
    public void MissingIsBoldFallsBackToResolverTraitsNotTheConstructorDefault()
    {
        // With no ITextStyleFontResolver registered, the seam yields (false, false) — this
        // deliberately differs from `new TextStyle()`'s isBold=true until the Windows renderer
        // wires a real resolver (see TextStyleFontResolver's doc comment).
        const string json = """{"fontName": "Helvetica-Bold"}""";
        TextStyleFontResolver.Current.ShouldBeNull();
        var style = JsonSerializer.Deserialize<TextStyle>(json)!;
        style.IsBold.ShouldBeFalse();
        style.IsItalic.ShouldBeFalse();
    }

    [Fact]
    public void ExplicitIsBoldIsBoldIsNeverOverriddenByTheResolver()
    {
        var fake = new FakeFontResolver(true, true);
        TextStyleFontResolver.Current = fake;
        try
        {
            const string json = """{"fontName": "Helvetica-Bold", "isBold": false, "isItalic": false}""";
            var style = JsonSerializer.Deserialize<TextStyle>(json)!;
            style.IsBold.ShouldBeFalse();
            style.IsItalic.ShouldBeFalse();
            fake.CallCount.ShouldBe(0); // both keys present -> resolver never consulted
        }
        finally
        {
            TextStyleFontResolver.Current = null;
        }
    }

    [Fact]
    public void MissingIsBoldConsultsTheRegisteredResolver()
    {
        TextStyleFontResolver.Current = new FakeFontResolver(true, false);
        try
        {
            const string json = """{"fontName": "SomeFont"}""";
            var style = JsonSerializer.Deserialize<TextStyle>(json)!;
            style.IsBold.ShouldBeTrue();
            style.IsItalic.ShouldBeFalse();
        }
        finally
        {
            TextStyleFontResolver.Current = null;
        }
    }

    [Fact]
    public void MalformedNestedColorFallsBackToDefaultRgba()
    {
        // color is a plain-Codable nested type with no custom init — a partial object fails the
        // whole nested decode, which TextStyle's `try? ... ?? default` swallows (same pattern as
        // Clip.crop in ProjectRoundTripTests.cs).
        const string json = """{"color": {"r": 1, "g": 0}}""";
        var style = JsonSerializer.Deserialize<TextStyle>(json)!;
        style.Color.R.ShouldBe(1); // default RGBA(), not the partially-specified value
        style.Color.A.ShouldBe(1);
    }

    [Fact]
    public void MalformedShadowFallsBackToDefaultShadow()
    {
        const string json = """{"shadow": {"enabled": true}}""";
        var style = JsonSerializer.Deserialize<TextStyle>(json)!;
        style.Shadow.OffsetY.ShouldBe(-2);
        style.Shadow.Blur.ShouldBe(6);
    }

    [Fact]
    public void UnknownAlignmentFallsBackToCenter()
    {
        const string json = """{"alignment": "justify"}""";
        var style = JsonSerializer.Deserialize<TextStyle>(json)!;
        style.Alignment.ShouldBe(TextStyleAlignment.Center);
    }

    [Fact]
    public void GlyphBorderPaddingMatchesSwiftFormula()
    {
        // ceil(fontSize * abs(-4) / 100).
        TextStyle.GlyphBorderPadding(96).ShouldBe(Math.Ceiling(96 * 4.0 / 100));
        TextStyle.GlyphBorderPadding(25).ShouldBe(1.0);
    }

    private sealed class FakeFontResolver(bool bold, bool italic) : ITextStyleFontResolver
    {
        public int CallCount { get; private set; }

        public (bool IsBold, bool IsItalic) SymbolicTraits(string fontName, double fontSize)
        {
            CallCount++;
            return (bold, italic);
        }
    }
}

/// Mirrors Tests/PalmierProTests/Rendering/RGBAHexTests.swift.
public class TextStyleRgbaHexTests
{
    [Fact]
    public void ThreeDigitExpandsEachChannel()
    {
        var c = TextStyleRgba.FromHex("F0A")!;
        c.R.ShouldBe(1.0);
        c.G.ShouldBe(0);
        Math.Abs(c.B - 170.0 / 255.0).ShouldBeLessThan(1e-9);
        c.A.ShouldBe(1);
    }

    [Fact]
    public void ThreeDigitWhiteIsAllOnes()
    {
        var c = TextStyleRgba.FromHex("fff")!;
        c.R.ShouldBe(1);
        c.G.ShouldBe(1);
        c.B.ShouldBe(1);
        c.A.ShouldBe(1);
    }

    [Fact]
    public void SixDigitParsesEachChannelAsByteAndDefaultsAlphaToOne()
    {
        var c = TextStyleRgba.FromHex("FF8800")!;
        c.R.ShouldBe(1);
        Math.Abs(c.G - 136.0 / 255.0).ShouldBeLessThan(1e-9);
        c.B.ShouldBe(0);
        c.A.ShouldBe(1);
    }

    [Fact]
    public void EightDigitIncludesAlphaChannel()
    {
        var c = TextStyleRgba.FromHex("FF880080")!;
        c.R.ShouldBe(1);
        Math.Abs(c.A - 128.0 / 255.0).ShouldBeLessThan(1e-9);
    }

    [Fact]
    public void EightDigitFullAlphaMatchesSixDigit()
    {
        var six = TextStyleRgba.FromHex("112233")!;
        var eight = TextStyleRgba.FromHex("112233FF")!;
        six.R.ShouldBe(eight.R);
        six.G.ShouldBe(eight.G);
        six.B.ShouldBe(eight.B);
        eight.A.ShouldBe(1);
    }

    [Fact]
    public void LeadingHashIsOptional()
    {
        var withHash = TextStyleRgba.FromHex("#FF0000")!;
        var without = TextStyleRgba.FromHex("FF0000")!;
        withHash.R.ShouldBe(without.R);
        withHash.G.ShouldBe(without.G);
        withHash.B.ShouldBe(without.B);
    }

    [Fact]
    public void SurroundingWhitespaceAndNewlinesAreTrimmed()
    {
        var c = TextStyleRgba.FromHex("   #00FF00  ")!;
        c.R.ShouldBe(0);
        c.G.ShouldBe(1);
        c.B.ShouldBe(0);

        var trailing = TextStyleRgba.FromHex("#00FF00\n")!;
        trailing.G.ShouldBe(1);

        var surrounding = TextStyleRgba.FromHex("\r\n  #00FF00  \n")!;
        surrounding.G.ShouldBe(1);
    }

    [Fact]
    public void EmptyStringReturnsNull()
    {
        TextStyleRgba.FromHex("").ShouldBeNull();
        TextStyleRgba.FromHex("#").ShouldBeNull();
    }

    [Theory]
    [InlineData("FF")]
    [InlineData("FFFF")]
    [InlineData("FFFFF")]
    [InlineData("FFFFFFF")]
    [InlineData("FFFFFFFFF")]
    public void WrongLengthReturnsNull(string hex) => TextStyleRgba.FromHex(hex).ShouldBeNull();

    [Theory]
    [InlineData("GG0000")]
    [InlineData("ZZZ")]
    [InlineData("QWERTYUI")]
    public void NonHexCharactersReturnNull(string hex) => TextStyleRgba.FromHex(hex).ShouldBeNull();

    [Fact]
    public void AcceptsLowercaseAndMixedCase()
    {
        var upper = TextStyleRgba.FromHex("FF8800")!;
        var lower = TextStyleRgba.FromHex("ff8800")!;
        var mixed = TextStyleRgba.FromHex("Ff8800")!;
        upper.R.ShouldBe(lower.R);
        lower.R.ShouldBe(mixed.R);
        upper.G.ShouldBe(lower.G);
        lower.G.ShouldBe(mixed.G);
    }

    [Fact]
    public void RejectsZeroXPrefix() => TextStyleRgba.FromHex("0xFF8800").ShouldBeNull();

    [Fact]
    public void RejectsEmbeddedWhitespace() => TextStyleRgba.FromHex("FF 00 00").ShouldBeNull();
}

/// Mirrors the "no Swift custom decoder anywhere in the chain -> fully required" pattern used
/// throughout ProjectRoundTripTests.cs, applied to TextStyle's plain-Codable nested types.
public class TextStyleNestedStrictnessTests
{
    [Fact]
    public void RgbaThrowsWhenAnyComponentIsMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<TextStyleRgba>("""{"r": 1, "g": 1, "b": 1}"""));
    }

    [Fact]
    public void ShadowThrowsWhenAnyFieldIsMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<TextStyleShadow>(
            """{"enabled": true, "color": {"r": 0, "g": 0, "b": 0, "a": 1}, "offsetX": 0, "offsetY": 0}"""));
    }

    [Fact]
    public void FillThrowsWhenColorIsMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<TextStyleFill>("""{"enabled": true}"""));
    }
}
