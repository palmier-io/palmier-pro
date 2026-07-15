namespace PalmierPro.Services.Export;

/// A resolved font family + face name, e.g. `("Helvetica", "Bold")`. `Face` is either the font's
/// own native face name (when it actually carries the requested bold/italic traits) or one of the
/// four canonical fallbacks ("Regular"/"Bold"/"Italic"/"Bold Italic") when it doesn't — mirrors
/// `FCPXMLExporter.fontFace(for:resolvedFont:)`/`fontFaceFallback`.
public readonly record struct ResolvedFontFace(string Family, string Face);

/// Seam replacing `TextStyle.resolvedFont`/`CTFontGetSymbolicTraits` (NSFont + CoreText symbolic
/// traits) for FCPXML text-clip export: given a stored font name (which may be a bare family like
/// "Helvetica" or a PostScript full name like "Helvetica-Bold") and the clip's requested
/// bold/italic flags, resolve the family FCP/Resolve should look up and the face name to write
/// into `text-style`'s `fontFace` attribute. `FcpxmlExporter` takes this as a dependency; exporter
/// tests inject a fake so they never touch the system font collection.
public interface IFontTraitResolver
{
    ResolvedFontFace Resolve(string fontName, double fontSize, bool isBold, bool isItalic);
}
