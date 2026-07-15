#pragma once

#include <dwrite_3.h>
#include <wrl/client.h>

#include <mutex>
#include <string>
#include <unordered_map>

// Process-wide bundled-font registry for the native text/title compositor (E4's Fonts
// deliverable). Builds one IDWriteFactory5 custom font set from the files under fonts\
// next to PalmierEngine.dll — deployed by PalmierPro.Rendering.csproj's Content items
// directly from Sources/PalmierPro/Resources/Fonts (the Mac app's own bundle source;
// referenced, never duplicated, so both platforms register the same 13 font families
// Utilities/BundledFonts.swift does).
//
// IDWriteFactory5/IDWriteFontSetBuilder1 specifically (not the plain IDWriteFactory):
// a font set built via AddFontFile automatically expands a variable font's named
// instances into distinct weight-differentiated entries within its family — Caveat,
// DMSans, Geist, GeistMono (regular + italic), Inter, PlayfairDisplay and SpaceGrotesk
// are the variable families among the 13, and this is what makes their weight axis
// resolve like any static family below, with no per-instance bookkeeping here.
// CreateFontCollectionFromFontSet groups those entries with the classic weight/stretch/
// style family model (its default when no model is specified), matching how
// TextStyle.swift stores one family name per style and resolves isBold/isItalic against
// whichever faces that family actually has (TextStyle.resolvedFont) rather than storing
// a separate name per weight.
//
// Lookup mirrors the plan's fonts contract: exact bundled family name match, else the
// fixed fallback family below — never "closest available" or "first available", so a
// project with an unresolvable font name renders identically on repeat opens. The Mac
// default is "Helvetica-Bold" (Models/TextStyle.swift:8), which isn't bundled (Apple's
// license forbids shipping Helvetica off-Apple platforms) and so always takes the
// fallback branch, same as any other missing/unknown name.
class FontRegistry
{
public:
    static FontRegistry& Instance();

    FontRegistry(const FontRegistry&) = delete;
    FontRegistry& operator=(const FontRegistry&) = delete;

    // Idempotent and thread-safe (the render thread and PE_DebugResolveFontFamily probes
    // may both call it). False only if the fonts directory is missing/empty or DirectWrite
    // factory/font-set creation failed outright — callers should treat that as "titles
    // render with no bundled fonts" rather than fatal; ResolveFamily still returns a
    // deterministic name in that case, it just won't be present in Collection().
    bool EnsureInitialized(std::string& outError);

    // Bundled families only — no system fonts baked in (system-font fallback for
    // arbitrary names is the C#/XAML FontPickerField's job, per the plan, not this
    // collection's). Null until EnsureInitialized has succeeded.
    IDWriteFontCollection1* Collection() const { return collection_.Get(); }

    // Maps a TextStyle.fontName value to the family name to look up in Collection():
    // the exact bundled family (case-insensitive) if present, else kFallbackFamily.
    // Always returns a name that IS present in Collection() once EnsureInitialized has
    // succeeded (kFallbackFamily is always one of the bundled families). Safe to call
    // before EnsureInitialized (returns the deterministic name regardless; it just may
    // not resolve to an actual family yet).
    std::wstring ResolveFamily(const std::string& storedFontName) const;

    // Convenience for the text renderer: resolves storedFontName via ResolveFamily, then
    // picks the closest face for the requested weight/style within that family —
    // IDWriteFontFamily::GetFirstMatchingFont, the same mechanism DirectWriteFontTrait
    // Resolver.cs (Export) uses against the system collection. False if the family isn't
    // in Collection() (EnsureInitialized failed or never called) or has no matching face.
    bool TryGetMatchingFont(
        const std::string& storedFontName,
        bool bold,
        bool italic,
        Microsoft::WRL::ComPtr<IDWriteFont>& outFont) const;

    // Closest bundled analog to Helvetica Bold: a geometric grotesque with true static
    // Regular/Bold/Italic/BoldItalic faces (Sources/PalmierPro/Resources/Fonts/Poppins/),
    // so isBold/isItalic combinations resolve to real faces rather than synthesized ones.
    static constexpr const wchar_t* kFallbackFamily = L"Poppins";

private:
    FontRegistry() = default;

    bool ResolveFontsDir(std::string& outError);
    bool BuildFontSet(std::string& outError);

    std::mutex mutex_;
    bool initialized_ = false;
    bool initSucceeded_ = false;
    std::string initError_;

    std::string fontsDir_;
    Microsoft::WRL::ComPtr<IDWriteFactory5> factory_;
    Microsoft::WRL::ComPtr<IDWriteFontCollection1> collection_;

    // Lowercased UTF-8 family name -> actual (correctly-cased) family name, for
    // case-insensitive exact match in ResolveFamily.
    std::unordered_map<std::string, std::wstring> familyNamesLower_;
};
