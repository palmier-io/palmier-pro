using System.Runtime.InteropServices;
using System.Text;

namespace PalmierPro.Services.Export;

/// `IFontTraitResolver` backed by the system DirectWrite font collection, replacing the Mac's
/// `NSFont(name:size:)` + `CTFontGetSymbolicTraits`/`CTFontDescriptorCreateCopyWithSymbolicTraits`
/// pair (`TextStyle.resolvedFont`/`FCPXMLExporter.fontFace`). `fontName` may be a bare family
/// ("Helvetica") or a PostScript full name ("Helvetica-Bold") — DirectWrite's font collection only
/// matches family names, so an unmatched name is retried against its hyphen-split prefix
/// (`FontFamilyFallback`, mirroring the Swift `fontFamilyFallback`).
///
/// If DirectWrite is unavailable (construction failed) `Resolve` degrades to the name-fallback +
/// canonical face string, same as when a family/face genuinely can't be matched — it never throws.
public sealed class DirectWriteFontTraitResolver : IFontTraitResolver, IDisposable
{
    private readonly IDWriteFactory? _factory;
    private readonly IDWriteFontCollection? _systemFonts;

    public DirectWriteFontTraitResolver()
    {
        if (DWriteNative.DWriteCreateFactory(DWriteFactoryType.Shared, DWriteNative.IID_IDWriteFactory, out var factory) < 0)
        {
            return;
        }
        _factory = factory;
        if (_factory.GetSystemFontCollection(out var collection, checkForUpdates: false) >= 0)
        {
            _systemFonts = collection;
        }
    }

    public ResolvedFontFace Resolve(string fontName, double fontSize, bool isBold, bool isItalic)
    {
        var fallbackFamily = FontFamilyFallback(fontName);
        if (_systemFonts is null)
        {
            return new ResolvedFontFace(fallbackFamily, FallbackFace(isBold, isItalic));
        }

        var resolved = FindFamily(fontName) ?? FindFamily(fallbackFamily);
        if (resolved is not (string familyName, IDWriteFontFamily family))
        {
            return new ResolvedFontFace(fallbackFamily, FallbackFace(isBold, isItalic));
        }

        var weight = isBold ? DWriteFontWeight.Bold : DWriteFontWeight.Normal;
        var style = isItalic ? DWriteFontStyle.Italic : DWriteFontStyle.Normal;
        if (family.GetFirstMatchingFont(weight, DWriteFontStretch.Normal, style, out var font) < 0)
        {
            return new ResolvedFontFace(familyName, FallbackFace(isBold, isItalic));
        }

        var actualIsBold = font.GetWeight() >= DWriteFontWeight.Bold;
        var actualIsItalic = font.GetStyle() != DWriteFontStyle.Normal;
        var matchesRequestedTraits = actualIsBold == isBold && actualIsItalic == isItalic;
        if (matchesRequestedTraits && ReadFaceName(font) is { } face)
        {
            return new ResolvedFontFace(familyName, face);
        }
        return new ResolvedFontFace(familyName, FallbackFace(isBold, isItalic));
    }

    private (string Name, IDWriteFontFamily Family)? FindFamily(string name)
    {
        var systemFonts = _systemFonts!;
        if (systemFonts.FindFamilyName(name, out var index, out var exists) < 0 || !exists)
        {
            return null;
        }
        return systemFonts.GetFontFamily(index, out var family) < 0 ? null : (name, family);
    }

    private static string? ReadFaceName(IDWriteFont font)
    {
        if (font.GetFaceNames(out var names) < 0 || names.GetStringLength(0, out var length) < 0)
        {
            return null;
        }
        var buffer = new StringBuilder((int)length + 1);
        return names.GetString(0, buffer, length + 1) < 0 ? null : buffer.ToString();
    }

    /// Mirrors `FCPXMLExporter.fontFamilyFallback`: the family segment of a PostScript full name
    /// ("Helvetica-Bold" -> "Helvetica"); names without a hyphen pass through unchanged.
    private static string FontFamilyFallback(string fontName)
    {
        var dash = fontName.IndexOf('-');
        return dash > 0 ? fontName[..dash] : fontName;
    }

    /// Mirrors `FCPXMLExporter.fontFaceFallback`.
    private static string FallbackFace(bool isBold, bool isItalic) => (isBold, isItalic) switch
    {
        (true, true) => "Bold Italic",
        (true, false) => "Bold",
        (false, true) => "Italic",
        (false, false) => "Regular",
    };

    public void Dispose()
    {
        if (_systemFonts is not null)
        {
            Marshal.ReleaseComObject(_systemFonts);
        }
        if (_factory is not null)
        {
            Marshal.ReleaseComObject(_factory);
        }
    }
}
