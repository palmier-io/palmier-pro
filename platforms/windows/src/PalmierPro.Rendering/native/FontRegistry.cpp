#include "FontRegistry.h"

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cwctype>
#include <filesystem>
#include <system_error>

using Microsoft::WRL::ComPtr;

namespace
{
    // Any function's address in this translation unit resolves the same module handle
    // (PalmierEngine.dll) — identical idiom to GpuCompositor.cpp's ResolveShadersDir.
    void AnchorFunction() {}

    std::string ToLowerAscii(std::string s)
    {
        std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        return s;
    }

    std::string WideToUtf8(const std::wstring& wide)
    {
        if (wide.empty())
        {
            return std::string();
        }
        int len = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
        std::string utf8(static_cast<size_t>(len > 0 ? len - 1 : 0), '\0');
        if (len > 0)
        {
            WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, utf8.data(), len, nullptr, nullptr);
        }
        return utf8;
    }

    // "dm sans 9pt" -> "dm sans"; empty when `lower` (already-lowercased) has no trailing
    // " <digits>pt" — the shape DirectWrite's weight/stretch/style family model gives an
    // optical-size variable font's per-size families (see BuildFontSet). Lets a stored name that
    // carries a point size DirectWrite never bundled as its own family (e.g. a size other than the
    // one this build's font file defaults to) still resolve via the bare typographic-family alias
    // instead of falling all the way through to kFallbackFamily.
    std::string StripOpticalSizeSuffixLower(const std::string& lower)
    {
        if (lower.size() < 3 || lower.compare(lower.size() - 2, 2, "pt") != 0)
        {
            return std::string();
        }
        size_t end = lower.size() - 2; // just past the digits, before "pt"
        size_t start = end;
        while (start > 0 && std::isdigit(static_cast<unsigned char>(lower[start - 1])))
        {
            --start;
        }
        if (start == end || start == 0 || lower[start - 1] != ' ')
        {
            return std::string(); // no digits, or no space separating them from the family name
        }
        return lower.substr(0, start - 1);
    }

    // Prefers en-us, falling back to whichever localization is first — mirrors
    // DirectWriteFontTraitResolver.cs's ReadFaceName (Export), the C#-side equivalent
    // against the system collection.
    std::wstring FirstLocalizedString(IDWriteLocalizedStrings* strings)
    {
        UINT32 index = 0;
        BOOL exists = FALSE;
        if (FAILED(strings->FindLocaleName(L"en-us", &index, &exists)) || !exists)
        {
            index = 0;
        }
        UINT32 length = 0;
        if (FAILED(strings->GetStringLength(index, &length)))
        {
            return std::wstring();
        }
        std::wstring result(length, L'\0');
        if (FAILED(strings->GetString(index, result.data(), length + 1)))
        {
            return std::wstring();
        }
        return result;
    }
}

FontRegistry& FontRegistry::Instance()
{
    static FontRegistry instance;
    return instance;
}

bool FontRegistry::ResolveFontsDir(std::string& outError)
{
    if (!fontsDir_.empty())
    {
        return true;
    }
    HMODULE hModule = nullptr;
    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCSTR>(&AnchorFunction), &hModule))
    {
        outError = "GetModuleHandleExA failed while resolving the fonts directory";
        return false;
    }
    char path[MAX_PATH]{};
    DWORD len = GetModuleFileNameA(hModule, path, MAX_PATH);
    if (len == 0 || len == MAX_PATH)
    {
        outError = "GetModuleFileNameA failed while resolving the fonts directory";
        return false;
    }
    std::string full(path, len);
    size_t slash = full.find_last_of("\\/");
    std::string dir = slash == std::string::npos ? "" : full.substr(0, slash + 1);
    fontsDir_ = dir + "fonts\\";
    return true;
}

bool FontRegistry::BuildFontSet(std::string& outError)
{
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory5),
        reinterpret_cast<IUnknown**>(factory_.GetAddressOf()))))
    {
        outError = "DWriteCreateFactory failed to produce an IDWriteFactory5";
        return false;
    }

    ComPtr<IDWriteFontSetBuilder1> builder;
    if (FAILED(factory_->CreateFontSetBuilder(&builder)))
    {
        outError = "IDWriteFactory5::CreateFontSetBuilder failed";
        return false;
    }

    std::error_code ec;
    auto it = std::filesystem::recursive_directory_iterator(
        std::filesystem::path(fontsDir_), std::filesystem::directory_options::skip_permission_denied, ec);
    if (ec)
    {
        outError = "cannot enumerate fonts directory: " + fontsDir_;
        return false;
    }
    std::filesystem::recursive_directory_iterator end;

    int32_t fileCount = 0;
    for (; it != end; it.increment(ec))
    {
        if (ec)
        {
            break;
        }
        std::error_code typeEc;
        if (!it->is_regular_file(typeEc) || typeEc)
        {
            continue;
        }
        std::wstring ext = it->path().extension().wstring();
        std::transform(ext.begin(), ext.end(), ext.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
        if (ext != L".ttf" && ext != L".otf")
        {
            continue;
        }

        ComPtr<IDWriteFontFile> fontFile;
        if (FAILED(factory_->CreateFontFileReference(it->path().c_str(), nullptr, &fontFile)))
        {
            continue; // one unreadable file must not fail the whole bundle
        }
        if (SUCCEEDED(builder->AddFontFile(fontFile.Get())))
        {
            ++fileCount;
        }
    }

    if (fileCount == 0)
    {
        outError = "no .ttf/.otf files found under " + fontsDir_;
        return false;
    }

    ComPtr<IDWriteFontSet> fontSet;
    if (FAILED(builder->CreateFontSet(&fontSet)))
    {
        outError = "IDWriteFontSetBuilder1::CreateFontSet failed";
        return false;
    }
    // No explicit family model: defaults to weight/stretch/style grouping — see this
    // file's header comment for why that's the model we want here.
    if (FAILED(factory_->CreateFontCollectionFromFontSet(fontSet.Get(), &collection_)))
    {
        outError = "IDWriteFactory5::CreateFontCollectionFromFontSet failed";
        return false;
    }

    UINT32 familyCount = collection_->GetFontFamilyCount();
    for (UINT32 i = 0; i < familyCount; ++i)
    {
        ComPtr<IDWriteFontFamily1> family;
        if (FAILED(collection_->GetFontFamily(i, &family)))
        {
            continue;
        }
        ComPtr<IDWriteLocalizedStrings> names;
        if (FAILED(family->GetFamilyNames(&names)))
        {
            continue;
        }
        std::wstring familyName = FirstLocalizedString(names.Get());
        if (familyName.empty())
        {
            continue;
        }
        familyNamesLower_[ToLowerAscii(WideToUtf8(familyName))] = familyName;

        // An optical-size variable font (DM Sans is the bundled example) has no plain family in
        // this collection: DirectWrite groups its named instances per optical size ("DM Sans
        // 14pt"), never under the bare typographic family. macOS CoreText groups the same font
        // file by typographic family (kCTFontFamilyNameAttribute), so a Mac-authored project
        // stores fontName="DM Sans" — alias that (name ID 16, DWRITE_INFORMATIONAL_STRING_
        // TYPOGRAPHIC_FAMILY_NAMES) to this bundled family too. `emplace` never overwrites an
        // already-registered key, so a real bundled family name always wins over an alias for the
        // same lowercased key, regardless of collection iteration order.
        if (family->GetFontCount() > 0)
        {
            ComPtr<IDWriteFont> firstFont;
            if (SUCCEEDED(family->GetFont(0, &firstFont)))
            {
                ComPtr<IDWriteLocalizedStrings> typographicNames;
                BOOL typographicExists = FALSE;
                if (SUCCEEDED(firstFont->GetInformationalStrings(
                        DWRITE_INFORMATIONAL_STRING_TYPOGRAPHIC_FAMILY_NAMES, &typographicNames,
                        &typographicExists)) &&
                    typographicExists && typographicNames)
                {
                    std::wstring typographicName = FirstLocalizedString(typographicNames.Get());
                    if (!typographicName.empty())
                    {
                        familyNamesLower_.emplace(ToLowerAscii(WideToUtf8(typographicName)), familyName);
                    }
                }
            }
        }
    }

    return true;
}

bool FontRegistry::EnsureInitialized(std::string& outError)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (initialized_)
    {
        outError = initError_;
        return initSucceeded_;
    }
    initialized_ = true;

    std::string error;
    initSucceeded_ = ResolveFontsDir(error) && BuildFontSet(error);
    initError_ = error;
    outError = error;
    return initSucceeded_;
}

std::wstring FontRegistry::ResolveFamily(const std::string& storedFontName) const
{
    // familyNamesLower_ is populated once, inside EnsureInitialized's lock, and never
    // mutated again — safe to read here without locking.
    std::string lower = ToLowerAscii(storedFontName);
    auto exact = familyNamesLower_.find(lower);
    if (exact != familyNamesLower_.end())
    {
        return exact->second;
    }

    // "Helvetica-Bold" -> "Helvetica": the same PostScript-full-name split
    // DirectWriteFontTraitResolver.cs's FontFamilyFallback applies against the system
    // collection (Export), kept here for any other legacy stored name shaped that way.
    // Helvetica itself was never bundled, so the documented default still falls all the
    // way through to kFallbackFamily below.
    size_t dash = storedFontName.find('-');
    if (dash != std::string::npos && dash > 0)
    {
        auto prefixMatch = familyNamesLower_.find(ToLowerAscii(storedFontName.substr(0, dash)));
        if (prefixMatch != familyNamesLower_.end())
        {
            return prefixMatch->second;
        }
    }

    // "DM Sans 9pt" -> "DM Sans": a stored optical-size instance name DirectWrite didn't bundle
    // as its own family still resolves through the bare typographic-family alias BuildFontSet
    // registers (see above), rather than falling through to kFallbackFamily.
    std::string optical = StripOpticalSizeSuffixLower(lower);
    if (!optical.empty())
    {
        auto opticalMatch = familyNamesLower_.find(optical);
        if (opticalMatch != familyNamesLower_.end())
        {
            return opticalMatch->second;
        }
    }

    return kFallbackFamily;
}

bool FontRegistry::TryGetMatchingFont(
    const std::string& storedFontName,
    bool bold,
    bool italic,
    Microsoft::WRL::ComPtr<IDWriteFont>& outFont) const
{
    if (!collection_)
    {
        return false;
    }
    std::wstring family = ResolveFamily(storedFontName);

    UINT32 index = 0;
    BOOL exists = FALSE;
    if (FAILED(collection_->FindFamilyName(family.c_str(), &index, &exists)) || !exists)
    {
        return false;
    }
    ComPtr<IDWriteFontFamily1> fontFamily;
    if (FAILED(collection_->GetFontFamily(index, &fontFamily)))
    {
        return false;
    }

    DWRITE_FONT_WEIGHT weight = bold ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_NORMAL;
    DWRITE_FONT_STYLE style = italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;
    ComPtr<IDWriteFont> font;
    if (FAILED(fontFamily->GetFirstMatchingFont(weight, DWRITE_FONT_STRETCH_NORMAL, style, &font)))
    {
        return false;
    }
    outFont = font;
    return true;
}
