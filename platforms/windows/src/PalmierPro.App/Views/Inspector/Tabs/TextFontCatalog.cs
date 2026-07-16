using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Xaml.Media;

namespace PalmierPro.App.Views.Inspector.Tabs;

/// Font sources for TextTabView's font picker (M5) — DWrite system-font enumeration + the 13
/// bundled title/caption families. Mirrors Utilities/BundledFonts.swift's split: native
/// `FontRegistry` (native/FontRegistry.h) resolves the same 13 names at render time and explicitly
/// leaves "system-font fallback for arbitrary names" as "the C#/XAML FontPickerField's job" — this
/// is that job's Windows half.
public static class TextFontCatalog
{
    /// The 13 families native/FontRegistry.h bundles from Sources/PalmierPro/Resources/Fonts,
    /// alphabetical (mirrors Swift's `BundledFonts.families.sorted()`). A fixed list rather than one
    /// read from the .ttf files themselves — this project has no TTF name-table reader — verified
    /// against FontRegistryTests.cs's own InlineData for every one of these strings.
    public static readonly IReadOnlyList<string> BundledFamilies =
    [
        "Anton", "Basement Grotesque", "Bebas Neue", "Caveat", "DM Sans", "Geist", "Geist Mono",
        "Inter", "Permanent Marker", "Playfair Display", "Poppins", "Shrikhand", "Space Grotesk",
    ];

    /// ms-appx asset path for one representative file per bundled family — PalmierPro.App.csproj
    /// links every one of these from Sources/PalmierPro/Resources/Fonts into Assets/Fonts/.
    private static readonly IReadOnlyDictionary<string, string> BundledAssetPaths = new Dictionary<string, string>
    {
        ["Anton"] = "Assets/Fonts/Anton/Anton-Regular.ttf",
        ["Basement Grotesque"] = "Assets/Fonts/BasementGrotesque/BasementGrotesque-Black.ttf",
        ["Bebas Neue"] = "Assets/Fonts/BebasNeue/BebasNeue-Regular.ttf",
        ["Caveat"] = "Assets/Fonts/Caveat/Caveat-Variable.ttf",
        ["DM Sans"] = "Assets/Fonts/DMSans/DMSans-Variable.ttf",
        ["Geist"] = "Assets/Fonts/Geist/Geist-Variable.ttf",
        ["Geist Mono"] = "Assets/Fonts/GeistMono/GeistMono-Variable.ttf",
        ["Inter"] = "Assets/Fonts/Inter/Inter-Variable.ttf",
        ["Permanent Marker"] = "Assets/Fonts/PermanentMarker/PermanentMarker-Regular.ttf",
        ["Playfair Display"] = "Assets/Fonts/PlayfairDisplay/PlayfairDisplay-Variable.ttf",
        ["Poppins"] = "Assets/Fonts/Poppins/Poppins-Regular.ttf",
        ["Shrikhand"] = "Assets/Fonts/Shrikhand/Shrikhand-Regular.ttf",
        ["Space Grotesk"] = "Assets/Fonts/SpaceGrotesk/SpaceGrotesk-Variable.ttf",
    };

    /// A `FontFamily` that previews `familyName` in its own face — the bundled ms-appx file for one
    /// of <see cref="BundledFamilies"/>, else the plain system family name (WinUI resolves an
    /// installed family by name directly, no asset path needed).
    public static FontFamily PreviewFontFamily(string familyName) =>
        BundledAssetPaths.TryGetValue(familyName, out var path)
            ? new FontFamily($"ms-appx:///{path}#{familyName}")
            : new FontFamily(familyName);

    /// Family name to show in the font button — mirrors FontPickerField.swift's
    /// `NSFont(name: current)?.familyName ?? current`. A stored name is either already a bare
    /// family (nothing to do) or a PostScript full name ("Helvetica-Bold"); split on the first
    /// hyphen to recover the family, same convention as
    /// DirectWriteFontTraitResolver.FontFamilyFallback (Services/Export) and native
    /// FontRegistry::ResolveFamily. No BundledFamilies/SystemFamilies() membership check — the
    /// Mac's default caption font (Helvetica) isn't a Windows system font either, so requiring a
    /// match would leave the documented default ("Helvetica-Bold") unresolved.
    public static string DisplayFamilyName(string storedName)
    {
        var dash = storedName.IndexOf('-');
        return dash > 0 ? storedName[..dash] : storedName;
    }

    /// Installed system font family names, alphabetical. Empty (never throws) if DirectWrite is
    /// unavailable or enumeration fails — the picker just shows the bundled list in that case.
    public static IReadOnlyList<string> SystemFamilies()
    {
        try
        {
            return EnumerateSystemFamilies();
        }
        catch (COMException)
        {
            return [];
        }
    }

    private static List<string> EnumerateSystemFamilies()
    {
        var names = new List<string>();
        if (NativeDWrite.DWriteCreateFactory(DWriteFactoryType.Shared, NativeDWrite.IidIDWriteFactory, out var factory) < 0)
        {
            return names;
        }
        try
        {
            if (factory.GetSystemFontCollection(out var collection, checkForUpdates: false) < 0)
            {
                return names;
            }
            try
            {
                var count = collection.GetFontFamilyCount();
                for (uint i = 0; i < count; i++)
                {
                    if (collection.GetFontFamily(i, out var family) < 0)
                    {
                        continue;
                    }
                    try
                    {
                        AddFamilyName(family, names);
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(family);
                    }
                }
            }
            finally
            {
                Marshal.ReleaseComObject(collection);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(factory);
        }
        names.Sort(StringComparer.OrdinalIgnoreCase);
        return names;
    }

    // `object`-typed parameters, not the file-local COM interfaces directly: a `file` type can only
    // appear in a member signature belonging to another `file` type (CS9051) — TextFontCatalog
    // itself has to stay `internal` so TextTabView.xaml.cs (a different file) can call it. The cast
    // inside each body is what actually dispatches through the interface.

    private static void AddFamilyName(object familyObj, List<string> names)
    {
        var family = (IDWriteFontFamily)familyObj;
        if (family.GetFamilyNames(out var strings) < 0)
        {
            return;
        }
        try
        {
            if (FirstLocalizedString(strings) is { Length: > 0 } name)
            {
                names.Add(name);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(strings);
        }
    }

    /// Prefers en-us, falling back to whichever localization is first.
    private static string? FirstLocalizedString(object stringsObj)
    {
        var strings = (IDWriteLocalizedStrings)stringsObj;
        var index = 0u;
        if (strings.FindLocaleName("en-us", out var localeIndex, out var exists) >= 0 && exists)
        {
            index = localeIndex;
        }
        if (strings.GetStringLength(index, out var length) < 0)
        {
            return null;
        }
        var buffer = new StringBuilder((int)length + 1);
        return strings.GetString(index, buffer, length + 1) < 0 ? null : buffer.ToString();
    }
}

// Minimal classic-COM shim over DirectWrite (dwrite.dll — an OS component since Windows 7, no NuGet
// dependency), scoped to TextFontCatalog's family-name enumeration. Services/Export/DWriteInterop.cs
// resolves bold/italic traits for export against the same OS DLL, but its types are `internal` to
// PalmierPro.Services and so invisible here — this is a deliberately separate, minimal shim, not a
// duplicate-by-accident. GUIDs and vtable order verified against the Windows SDK's um/dwrite.h
// (10.0.26100.0); COM interop dispatches by declaration order, not by name, so an interface must
// declare every slot up to (and including) the last one this file actually calls — slots that come
// before a real one but are never themselves called stay as `_unused` stubs.

file enum DWriteFactoryType
{
    Shared = 0,
}

file static class NativeDWrite
{
    [DllImport("dwrite.dll", ExactSpelling = true, PreserveSig = true)]
    public static extern int DWriteCreateFactory(DWriteFactoryType factoryType, in Guid iid, out IDWriteFactory factory);

    public static readonly Guid IidIDWriteFactory = new("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");
}

[ComImport]
[Guid("b859ee5a-d838-4b5b-a2e8-1adc7d93db48")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
file interface IDWriteFactory
{
    [PreserveSig]
    int GetSystemFontCollection(out IDWriteFontCollection fontCollection, [MarshalAs(UnmanagedType.Bool)] bool checkForUpdates);
}

[ComImport]
[Guid("a84cee02-3eea-4eee-a827-87c1a02a0fcc")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
file interface IDWriteFontCollection
{
    [PreserveSig]
    uint GetFontFamilyCount();

    [PreserveSig]
    int GetFontFamily(uint index, out IDWriteFontFamily fontFamily);
}

/// `IDWriteFontFamily : IDWriteFontList`; the three `IDWriteFontList` slots land first in the real
/// vtable even though this shim never calls them.
[ComImport]
[Guid("da20d8ef-812a-4c43-9802-62ec4abd7add")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
file interface IDWriteFontFamily
{
    [PreserveSig] int GetFontCollectionUnused();
    [PreserveSig] int GetFontCountUnused();
    [PreserveSig] int GetFontUnused();

    [PreserveSig]
    int GetFamilyNames(out IDWriteLocalizedStrings names);
}

[ComImport]
[Guid("08256209-099a-4b34-b86d-c22b110e7771")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
file interface IDWriteLocalizedStrings
{
    [PreserveSig] int GetCountUnused();

    [PreserveSig]
    int FindLocaleName([MarshalAs(UnmanagedType.LPWStr)] string localeName, out uint index, [MarshalAs(UnmanagedType.Bool)] out bool exists);

    [PreserveSig] int GetLocaleNameLengthUnused();
    [PreserveSig] int GetLocaleNameUnused();

    [PreserveSig]
    int GetStringLength(uint index, out uint length);

    [PreserveSig]
    int GetString(uint index, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder stringBuffer, uint size);
}
