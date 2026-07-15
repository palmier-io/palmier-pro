using PalmierPro.Services.Export;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Export;

/// Exercises the real DirectWrite COM interop (`DWriteInterop.cs`) against the system font
/// collection. "Arial" and "Segoe UI" ship on every Windows install this app targets, so their
/// presence isn't an environment assumption worth faking around — unlike `FfprobeSourceTimingReader`,
/// which shells to a pinned binary, there is no fake-vs-real split to preserve here.
public sealed class DirectWriteFontTraitResolverTests
{
    [Fact]
    public void Resolve_KnownFamily_RegularTraits_ReturnsRealFaceName()
    {
        using var resolver = new DirectWriteFontTraitResolver();

        ResolvedFontFace result = resolver.Resolve("Arial", 24, isBold: false, isItalic: false);

        result.Family.ShouldBe("Arial");
        result.Face.ShouldNotBeNullOrWhiteSpace();
    }

    [Fact]
    public void Resolve_KnownFamily_BoldTrait_ReturnsAFaceDistinctFromRegular()
    {
        using var resolver = new DirectWriteFontTraitResolver();

        ResolvedFontFace regular = resolver.Resolve("Arial", 24, isBold: false, isItalic: false);
        ResolvedFontFace bold = resolver.Resolve("Arial", 24, isBold: true, isItalic: false);

        bold.Family.ShouldBe("Arial");
        bold.Face.ShouldNotBe(regular.Face);
    }

    [Fact]
    public void Resolve_PostScriptFullName_FallsBackToFamilyPrefix_AndStillMatchesTraits()
    {
        using var resolver = new DirectWriteFontTraitResolver();

        // "Arial-Bold" isn't itself a DirectWrite family name; FontFamilyFallback splits it to
        // "Arial" the same way FCPXMLExporter.fontFamilyFallback does on the Mac.
        ResolvedFontFace result = resolver.Resolve("Arial-Bold", 24, isBold: true, isItalic: false);

        result.Family.ShouldBe("Arial");
        result.Face.ShouldNotBeNullOrWhiteSpace();
    }

    [Fact]
    public void Resolve_UnknownFontName_FallsBackToHyphenSplitFamilyAndCanonicalFace()
    {
        using var resolver = new DirectWriteFontTraitResolver();

        ResolvedFontFace result = resolver.Resolve("PalmierProDoesNotShipThisFont-Bold", 24, isBold: true, isItalic: false);

        result.Family.ShouldBe("PalmierProDoesNotShipThisFont");
        result.Face.ShouldBe("Bold");
    }

    [Theory]
    [InlineData(false, false, "Regular")]
    [InlineData(true, false, "Bold")]
    [InlineData(false, true, "Italic")]
    [InlineData(true, true, "Bold Italic")]
    public void Resolve_UnknownFontName_UsesCanonicalFaceForEveryTraitCombination(bool isBold, bool isItalic, string expectedFace)
    {
        using var resolver = new DirectWriteFontTraitResolver();

        ResolvedFontFace result = resolver.Resolve("PalmierProDoesNotShipThisFont", 24, isBold, isItalic);

        result.Face.ShouldBe(expectedFace);
    }

    [Fact]
    public void Resolve_NoFamilyNameAndNoHyphen_PassesFontNameThroughUnchanged()
    {
        using var resolver = new DirectWriteFontTraitResolver();

        ResolvedFontFace result = resolver.Resolve("Helvetica", 24, isBold: false, isItalic: false);

        // "Helvetica" isn't a DirectWrite system family on Windows, so this hits the same fallback
        // path as the unknown-font tests — asserted separately since the family name (not the
        // canonical face) is the behavior under test here.
        result.Family.ShouldBe("Helvetica");
    }
}
