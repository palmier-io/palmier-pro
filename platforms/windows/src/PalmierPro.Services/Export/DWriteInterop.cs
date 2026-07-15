using System.Runtime.InteropServices;
using System.Text;

namespace PalmierPro.Services.Export;

// Minimal classic-COM shim over DirectWrite (dwrite.dll — an OS component since Windows 7, no
// NuGet dependency), covering only the vtable slots DirectWriteFontTraitResolver calls. GUIDs and
// method order verified against the Windows SDK's um/dwrite.h (10.0.26100.0). COM interop
// dispatches by declaration order, not by name, so slots this resolver never calls are still
// declared (as `_unused*` stubs) wherever a real slot comes after them in the same interface.

internal enum DWriteFactoryType
{
    Shared = 0,
}

/// Subset of `DWRITE_FONT_WEIGHT` — enough to request/compare "bold vs. not".
internal enum DWriteFontWeight
{
    Normal = 400,
    Bold = 700,
}

internal enum DWriteFontStretch
{
    Normal = 5,
}

internal enum DWriteFontStyle
{
    Normal = 0,
    Oblique = 1,
    Italic = 2,
}

internal static class DWriteNative
{
    [DllImport("dwrite.dll", ExactSpelling = true, PreserveSig = true)]
    internal static extern int DWriteCreateFactory(DWriteFactoryType factoryType, in Guid iid, out IDWriteFactory factory);

    internal static readonly Guid IID_IDWriteFactory = new("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");
}

[ComImport]
[Guid("b859ee5a-d838-4b5b-a2e8-1adc7d93db48")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDWriteFactory
{
    [PreserveSig]
    int GetSystemFontCollection(out IDWriteFontCollection fontCollection, [MarshalAs(UnmanagedType.Bool)] bool checkForUpdates);
}

[ComImport]
[Guid("a84cee02-3eea-4eee-a827-87c1a02a0fcc")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDWriteFontCollection
{
    [PreserveSig] int GetFontFamilyCount_unused();

    [PreserveSig]
    int GetFontFamily(uint index, out IDWriteFontFamily fontFamily);

    [PreserveSig]
    int FindFamilyName([MarshalAs(UnmanagedType.LPWStr)] string familyName, out uint index, [MarshalAs(UnmanagedType.Bool)] out bool exists);
}

/// `IDWriteFontFamily : IDWriteFontList`; the three `IDWriteFontList` slots land first in the
/// real vtable even though this shim never calls them.
[ComImport]
[Guid("da20d8ef-812a-4c43-9802-62ec4abd7add")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDWriteFontFamily
{
    [PreserveSig] int GetFontCollection_unused();
    [PreserveSig] int GetFontCount_unused();
    [PreserveSig] int GetFont_unused();
    [PreserveSig] int GetFamilyNames_unused();

    [PreserveSig]
    int GetFirstMatchingFont(DWriteFontWeight weight, DWriteFontStretch stretch, DWriteFontStyle style, out IDWriteFont matchingFont);
}

[ComImport]
[Guid("acd16696-8c14-4f5d-877e-fe3fc1d32737")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDWriteFont
{
    [PreserveSig] int GetFontFamily_unused();

    [PreserveSig]
    DWriteFontWeight GetWeight();

    [PreserveSig] int GetStretch_unused();

    [PreserveSig]
    DWriteFontStyle GetStyle();

    [PreserveSig] int IsSymbolFont_unused();

    [PreserveSig]
    int GetFaceNames(out IDWriteLocalizedStrings names);
}

[ComImport]
[Guid("08256209-099a-4b34-b86d-c22b110e7771")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IDWriteLocalizedStrings
{
    [PreserveSig] int GetCount_unused();
    [PreserveSig] int FindLocaleName_unused();
    [PreserveSig] int GetLocaleNameLength_unused();
    [PreserveSig] int GetLocaleName_unused();

    [PreserveSig]
    int GetStringLength(uint index, out uint length);

    [PreserveSig]
    int GetString(uint index, [MarshalAs(UnmanagedType.LPWStr)] StringBuilder stringBuffer, uint size);
}
