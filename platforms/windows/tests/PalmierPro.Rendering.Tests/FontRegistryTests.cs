using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// Exercises FontRegistry (native/FontRegistry.h) through the PE_DebugResolveFontFamily ABI
// probe — the plan's "13 bundled families; Helvetica-Bold + missing names map
// deterministically to a bundled fallback" contract. No MediaFixtures needed: this never
// touches the FFmpeg decode path, only the bundled fonts\ directory PalmierPro.Rendering.csproj
// stages next to PalmierEngine.dll.
public sealed class FontRegistryTests
{
    [Theory]
    [Trait("Category", "Media")]
    [InlineData("Poppins")]
    [InlineData("Inter")]
    [InlineData("Anton")]
    [InlineData("Basement Grotesque")]
    [InlineData("Bebas Neue")]
    [InlineData("Caveat")]
    // Actual DirectWrite/font-table family name (an "opsz" optical-size axis, not just
    // "wght", is part of this variable font's default named instance) — not "DM Sans".
    // Both platforms read the exact same font files, so this is the name a stored
    // TextStyle.fontName must match exactly to round-trip, on either platform.
    [InlineData("DM Sans 14pt")]
    [InlineData("Geist")]
    [InlineData("Geist Mono")]
    [InlineData("Permanent Marker")]
    [InlineData("Playfair Display")]
    [InlineData("Shrikhand")]
    [InlineData("Space Grotesk")]
    public void ResolveFamily_BundledFamily_ResolvesToItself(string bundledFamily)
    {
        FontRegistryDebug.ResolveFamily(bundledFamily).ShouldBe(bundledFamily);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ResolveFamily_IsCaseInsensitive()
    {
        FontRegistryDebug.ResolveFamily("POPPINS").ShouldBe("Poppins");
        FontRegistryDebug.ResolveFamily("poppins").ShouldBe("Poppins");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ResolveFamily_HelveticaBold_MapsToDeterministicFallback()
    {
        // Mac's stored default (Models/TextStyle.swift:8) — Helvetica isn't bundled/licensed
        // for Windows, so this must resolve the same way on every run.
        string resolved = FontRegistryDebug.ResolveFamily("Helvetica-Bold");
        resolved.ShouldBe("Poppins");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ResolveFamily_UnknownName_MapsToSameDeterministicFallback()
    {
        FontRegistryDebug.ResolveFamily("Comic Sans MS").ShouldBe(FontRegistryDebug.ResolveFamily("Helvetica-Bold"));
        FontRegistryDebug.ResolveFamily("Some Font Nobody Bundled").ShouldBe("Poppins");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ResolveFamily_RepeatedCalls_AreStable()
    {
        // EnsureInitialized is idempotent/lazy — a second resolution (any name) must not
        // change a prior resolution's result.
        string first = FontRegistryDebug.ResolveFamily("Inter");
        string second = FontRegistryDebug.ResolveFamily("Inter");
        second.ShouldBe(first);
    }

    // DM Sans is an optical-size variable font: DirectWrite groups its named instances per size
    // ("DM Sans 14pt", the literal bundled family — see the InlineData above) and exposes no plain
    // "DM Sans" family, while macOS CoreText groups the same font file by typographic family
    // ("DM Sans"). A Mac-authored project stores the CoreText name, so it must resolve to the
    // bundled family here too, not fall through to the Poppins fallback.
    [Fact]
    [Trait("Category", "Media")]
    public void ResolveFamily_DmSansTypographicAlias_ResolvesToBundledFamily()
    {
        FontRegistryDebug.ResolveFamily("DM Sans").ShouldBe("DM Sans 14pt");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void ResolveFamily_DmSansTypographicAlias_IsCaseInsensitive()
    {
        FontRegistryDebug.ResolveFamily("dm sans").ShouldBe("DM Sans 14pt");
        FontRegistryDebug.ResolveFamily("DM SANS").ShouldBe("DM Sans 14pt");
    }

    // A stored optical-size instance name this build didn't bundle as its own literal family
    // (only "DM Sans 14pt" is bundled) must still resolve through the typographic-family alias
    // rather than silently falling back to Poppins.
    [Fact]
    [Trait("Category", "Media")]
    public void ResolveFamily_DmSansUnbundledOpticalSize_ResolvesToBundledFamily_NotFallback()
    {
        FontRegistryDebug.ResolveFamily("DM Sans 9pt").ShouldBe("DM Sans 14pt");
        FontRegistryDebug.ResolveFamily("DM Sans 9pt").ShouldNotBe("Poppins");
    }
}
