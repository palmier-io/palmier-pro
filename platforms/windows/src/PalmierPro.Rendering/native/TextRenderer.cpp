#include "TextRenderer.h"
#include "FontRegistry.h"
#include "TextAnimator.h"

#include <windows.h>
#include <wincodec.h>

#include <algorithm>
#include <cmath>

using Microsoft::WRL::ComPtr;

namespace
{
    // Models/TextLayout.swift:7 — style sizes are authored against a 1080p canvas and scaled by
    // renderHeight / referenceCanvasHeight.
    constexpr double kReferenceCanvasHeight = 1080.0;

    // Models/TextStyle.swift:6 — glyphBorderStrokeWidth = -4 (CoreText % of font size; negative =
    // fill AND stroke). |−4|/100 * fontSize is the stroke line width.
    constexpr double kGlyphBorderStrokeWidthPct = 4.0;

    std::wstring Utf8ToWide(const std::string& utf8)
    {
        if (utf8.empty())
        {
            return std::wstring();
        }
        int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
        std::wstring wide(static_cast<size_t>(len > 0 ? len - 1 : 0), L'\0');
        if (len > 0)
        {
            MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, wide.data(), len);
        }
        return wide;
    }

    D2D1_COLOR_F ToColorF(const SnapshotRgba& c)
    {
        // sRGB-encoded values used verbatim — non-color-managed working space (the Mac's NSNull
        // CIContext working color space). D2D premultiplies against the target's PREMULTIPLIED
        // alpha mode internally.
        return D2D1::ColorF(static_cast<float>(c.r), static_cast<float>(c.g),
                            static_cast<float>(c.b), static_cast<float>(c.a));
    }

    DWRITE_TEXT_ALIGNMENT AlignmentFromRaw(const std::string& raw)
    {
        // TextStyle.paragraphStyle (TextStyle.swift:137-146): left|center|right.
        if (raw == "left") return DWRITE_TEXT_ALIGNMENT_LEADING;
        if (raw == "right") return DWRITE_TEXT_ALIGNMENT_TRAILING;
        return DWRITE_TEXT_ALIGNMENT_CENTER;
    }

    // A pivot-scale + vertical-shift transform, in absolute (canvas-pixel) coordinates: scales
    // about (cx, cy) by `scale`, then shifts the result by `dyPixels` (positive = down, D2D is
    // already y-down so no sign flip is needed here — contrast the Mac's `-st.dy * renderSize
    // .height` in FrameRenderer's CIImage y-up space). Mirrors applyEntrance's transform chain
    // (TextFrameRenderer.swift:100-106) and renderPerWord's per-word ctx transform (swift:157-163)
    // — same math, expressed as one D2D matrix instead of a sequence of CGContext calls.
    D2D1_MATRIX_3X2_F PivotScaleDy(float cx, float cy, float scale, float dyPixels)
    {
        return D2D1::Matrix3x2F::Translation(-cx, -cy)
             * D2D1::Matrix3x2F::Scale(scale, scale)
             * D2D1::Matrix3x2F::Translation(cx, cy)
             * D2D1::Matrix3x2F::Translation(0.0f, dyPixels);
    }

    // Custom text renderer: DirectWrite hands us positioned glyph runs (respecting the layout's
    // alignment / word-wrap), and we fill+stroke their OUTLINES via ID2D1Factory::CreatePathGeometry
    // so a border stroke is available — the exact fill+stroke pairing CoreText produces from a
    // negative strokeWidth (TextStyle.attributes, swift:155-158). DrawTextLayout alone can't stroke.
    // Reused across whole-clip (entrance/typewriter, one Draw() call) and per-word (one Draw() call
    // per token, brush color/opacity mutated between calls) — it only ever reads whatever the
    // fill/stroke/shadow brush pointers currently hold, so the caller drives all per-word variation
    // by mutating those brushes and the render target's transform before each Draw() call.
    class GlyphOutlineRenderer : public IDWriteTextRenderer
    {
    public:
        GlyphOutlineRenderer(ID2D1Factory* d2dFactory, ID2D1RenderTarget* rt,
                             ID2D1SolidColorBrush* fill, ID2D1SolidColorBrush* stroke,
                             ID2D1SolidColorBrush* shadow, bool borderEnabled, float strokeWidth,
                             bool shadowEnabled, float shadowDx, float shadowDy)
            : d2dFactory_(d2dFactory), rt_(rt), fill_(fill), stroke_(stroke), shadow_(shadow),
              borderEnabled_(borderEnabled), strokeWidth_(strokeWidth),
              shadowEnabled_(shadowEnabled), shadowDx_(shadowDx), shadowDy_(shadowDy)
        {
        }

        HRESULT __stdcall DrawGlyphRun(void*, FLOAT baselineOriginX, FLOAT baselineOriginY,
            DWRITE_MEASURING_MODE, const DWRITE_GLYPH_RUN* glyphRun,
            const DWRITE_GLYPH_RUN_DESCRIPTION*, IUnknown*) override
        {
            if (!glyphRun || glyphRun->glyphCount == 0 || !glyphRun->fontFace)
            {
                return S_OK;
            }
            ComPtr<ID2D1PathGeometry> path;
            if (FAILED(d2dFactory_->CreatePathGeometry(&path)))
            {
                return S_OK;
            }
            ComPtr<ID2D1GeometrySink> sink;
            if (FAILED(path->Open(&sink)))
            {
                return S_OK;
            }
            // Outline is emitted in y-down design space relative to the baseline origin (glyph body
            // at negative y = above the baseline); translating by the baseline origin places it.
            HRESULT hr = glyphRun->fontFace->GetGlyphRunOutline(
                glyphRun->fontEmSize, glyphRun->glyphIndices, glyphRun->glyphAdvances,
                glyphRun->glyphOffsets, glyphRun->glyphCount, glyphRun->isSideways,
                (glyphRun->bidiLevel % 2) != 0, sink.Get());
            sink->Close();
            if (FAILED(hr))
            {
                return S_OK;
            }

            D2D1_MATRIX_3X2_F saved;
            rt_->GetTransform(&saved);

            if (shadowEnabled_ && shadow_)
            {
                // Hard offset, no blur — required E4 follow-up, see TextRenderer.h.
                rt_->SetTransform(D2D1::Matrix3x2F::Translation(baselineOriginX + shadowDx_,
                                                                baselineOriginY + shadowDy_) * saved);
                rt_->FillGeometry(path.Get(), shadow_);
            }

            rt_->SetTransform(D2D1::Matrix3x2F::Translation(baselineOriginX, baselineOriginY) * saved);
            rt_->FillGeometry(path.Get(), fill_);
            if (borderEnabled_ && stroke_)
            {
                rt_->DrawGeometry(path.Get(), stroke_, strokeWidth_);
            }

            rt_->SetTransform(saved);
            return S_OK;
        }

        HRESULT __stdcall DrawInlineObject(void*, FLOAT, FLOAT, IDWriteInlineObject*, BOOL, BOOL,
            IUnknown*) override { return S_OK; }
        HRESULT __stdcall DrawUnderline(void*, FLOAT, FLOAT, const DWRITE_UNDERLINE*, IUnknown*) override { return S_OK; }
        HRESULT __stdcall DrawStrikethrough(void*, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH*, IUnknown*) override { return S_OK; }

        // Disable pixel snapping so glyph baselines keep subpixel positions, matching the Mac's
        // setShouldSubpixelPositionFonts(true) (TextFrameRenderer.beginContext, swift:61-62).
        HRESULT __stdcall IsPixelSnappingDisabled(void*, BOOL* isDisabled) override { *isDisabled = TRUE; return S_OK; }
        HRESULT __stdcall GetCurrentTransform(void*, DWRITE_MATRIX* transform) override
        {
            rt_->GetTransform(reinterpret_cast<D2D1_MATRIX_3X2_F*>(transform));
            return S_OK;
        }
        HRESULT __stdcall GetPixelsPerDip(void*, FLOAT* pixelsPerDip) override { *pixelsPerDip = 1.0f; return S_OK; }

        // Stack-scoped: `layout->Draw` never retains the renderer beyond the call, so refcounting is
        // a formality here.
        HRESULT __stdcall QueryInterface(REFIID riid, void** ppv) override
        {
            if (riid == __uuidof(IUnknown) || riid == __uuidof(IDWritePixelSnapping) ||
                riid == __uuidof(IDWriteTextRenderer))
            {
                *ppv = this;
                return S_OK;
            }
            *ppv = nullptr;
            return E_NOINTERFACE;
        }
        ULONG __stdcall AddRef() override { return 1; }
        ULONG __stdcall Release() override { return 1; }

    private:
        ID2D1Factory* d2dFactory_;
        ID2D1RenderTarget* rt_;
        ID2D1SolidColorBrush* fill_;
        ID2D1SolidColorBrush* stroke_;
        ID2D1SolidColorBrush* shadow_;
        bool borderEnabled_;
        float strokeWidth_;
        bool shadowEnabled_;
        float shadowDx_;
        float shadowDy_;
    };
}

bool TextRenderer::EnsureFactories(std::string& outError)
{
    if (!d2dFactory_)
    {
        if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2dFactory_.GetAddressOf())))
        {
            outError = "D2D1CreateFactory failed";
            return false;
        }
    }
    if (!dwriteFactory_)
    {
        // SHARED factory: the same process singleton FontRegistry builds its custom collection on,
        // so CreateTextFormat can reference FontRegistry::Collection() directly.
        if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory5),
                reinterpret_cast<IUnknown**>(dwriteFactory_.GetAddressOf()))))
        {
            outError = "DWriteCreateFactory(IDWriteFactory5) failed";
            return false;
        }
    }
    return true;
}

bool TextRenderer::Render(const SnapshotTextClip& clip, int64_t frame, int32_t canvasWidth,
    int32_t canvasHeight, Raster& out, std::string& outError)
{
    out = Raster{};
    // TextFrameRenderer.image guard (swift:11-13): degenerate canvas / empty content -> nil.
    if (canvasWidth < 1 || canvasHeight < 1 || clip.content.empty())
    {
        return true;
    }

    int64_t rel = frame - clip.startFrame;
    TextAnimator::RenderMode mode = TextAnimator::ModeFor(clip.animation.preset);

    // Whole-clip entrance opacity — TextAnimator.clipEntry (swift:22-35). Only fadeIn/popIn/
    // slideUp apply here; per-word/typewriter never fade the whole clip (renderPerWord /
    // renderTypewriter don't call clipEntry either — see TextFrameRenderer.image's dispatch,
    // swift:19-30).
    double finalAlphaScale = 1.0;
    if (mode == TextAnimator::RenderMode::Entrance)
    {
        finalAlphaScale = TextAnimator::ClipEntry(clip.animation, rel).opacity;
        if (finalAlphaScale <= 0.0)
        {
            return true; // fully faded entrance frame — nothing visible (applyEntrance opacity 0)
        }
    }

    if (!EnsureFactories(outError))
    {
        return false;
    }

    const int32_t W = canvasWidth;
    const int32_t H = canvasHeight;
    const double scale = static_cast<double>(H) / kReferenceCanvasHeight;

    // Font size — TextFrameRenderer.swift:16.
    const double fontSize = clip.style.fontSize * clip.style.fontScale * scale;

    // Box in y-down pixel space. TextFrameRenderer.boxRect (swift:43-48) computes it in CG y-up;
    // Transform.topLeft = (centerX - width/2, centerY - height/2) is top-down (Timeline.swift:495),
    // so in y-down the box top is simply tl.y*H. width/height take the same max(1, …) clamps the
    // Swift boxRect applies.
    const double tlX = clip.transform.centerX - clip.transform.width / 2.0;
    const double tlY = clip.transform.centerY - clip.transform.height / 2.0;
    const double boxLeft = tlX * W;
    const double boxTop = tlY * H;
    const double boxWidth = std::max(1.0, clip.transform.width * W);
    const double boxHeight = std::max(1.0, clip.transform.height * H); // for bg fill + entrance pivot
    // Framesetter path height in Swift is box.maxY (y-up) = H - tlY*H — i.e. the box top downward to
    // the canvas bottom, never clipping an overflowing line (swift:76-80). Mirror that extent.
    const double boxMaxHeight = std::max(1.0, static_cast<double>(H) - boxTop);

    // Font family resolution against the bundled collection (FontRegistry) — Helvetica-Bold and any
    // unknown name deterministically map to the bundled fallback (see FontRegistry.h).
    std::string fontInitError;
    FontRegistry::Instance().EnsureInitialized(fontInitError);
    IDWriteFontCollection1* collection = FontRegistry::Instance().Collection();
    std::wstring family = FontRegistry::Instance().ResolveFamily(clip.style.fontName);

    DWRITE_FONT_WEIGHT weight = clip.style.isBold ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_NORMAL;
    DWRITE_FONT_STYLE fontStyle = clip.style.isItalic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;

    // Builds a text format against the resolved family/weight/style/size, falling back to the
    // system collection if the bundled one somehow can't create it (titles render rather than
    // vanish). Shared by the full-content format and the per-word / typewriter variants below —
    // they differ only in alignment/wrap.
    auto makeFormat = [&](DWRITE_TEXT_ALIGNMENT align, DWRITE_WORD_WRAPPING wrap,
        ComPtr<IDWriteTextFormat>& out) -> bool
    {
        HRESULT h = dwriteFactory_->CreateTextFormat(family.c_str(), collection, weight, fontStyle,
            DWRITE_FONT_STRETCH_NORMAL, static_cast<float>(fontSize), L"", &out);
        if (FAILED(h) && collection != nullptr)
        {
            h = dwriteFactory_->CreateTextFormat(family.c_str(), nullptr, weight, fontStyle,
                DWRITE_FONT_STRETCH_NORMAL, static_cast<float>(fontSize), L"", &out);
        }
        if (FAILED(h))
        {
            return false;
        }
        out->SetTextAlignment(align);
        out->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR); // top-anchored (swift:76-80)
        out->SetWordWrapping(wrap);
        return true;
    };

    ComPtr<IDWriteTextFormat> format;
    if (!makeFormat(AlignmentFromRaw(clip.style.alignment), DWRITE_WORD_WRAPPING_WRAP, format))
    {
        outError = "IDWriteFactory::CreateTextFormat failed";
        return false;
    }

    std::wstring contentWide = Utf8ToWide(clip.content);
    ComPtr<IDWriteTextLayout> layout;
    HRESULT hr = dwriteFactory_->CreateTextLayout(contentWide.c_str(), static_cast<UINT32>(contentWide.size()),
        format.Get(), static_cast<float>(boxWidth), static_cast<float>(boxMaxHeight), &layout);
    if (FAILED(hr))
    {
        outError = "IDWriteFactory::CreateTextLayout failed";
        return false;
    }

    // Word tokenization + timing (TextAnimator::Tokenize/TokenTimings — TextFrameRenderer.swift's
    // words()/tokenTimings() ported). Cheap pure computation; harmless to do even when `mode` ends
    // up not needing it (Entrance).
    std::vector<TextAnimator::Token> tokens = TextAnimator::Tokenize(contentWide);
    std::vector<SnapshotWordTiming> tokenTimings =
        TextAnimator::TokenTimings(tokens, clip.wordTimings, clip.durationFrames);

    // Per-word text format: LEADING/NO_WRAP so each token draws as an independent single-line run
    // at an explicit origin, never re-centered or wrapped inside its own tiny layout — the
    // DirectWrite analog of the Mac drawing each word as its own left-anchored CTLine
    // (renderPerWord, swift:154-155).
    ComPtr<IDWriteTextFormat> wordFormat;
    if (mode == TextAnimator::RenderMode::PerWord)
    {
        if (!makeFormat(DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_WORD_WRAPPING_NO_WRAP, wordFormat))
        {
            outError = "IDWriteFactory::CreateTextFormat failed (per-word)";
            return false;
        }
    }

    // Typewriter text format: LEFT-anchored regardless of style.alignment so the revealed prefix
    // grows rightward in place instead of re-centering every frame (renderTypewriter, swift:219-224).
    ComPtr<IDWriteTextFormat> typewriterFormat;
    if (mode == TextAnimator::RenderMode::Typewriter)
    {
        if (!makeFormat(DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_WORD_WRAPPING_WRAP, typewriterFormat))
        {
            outError = "IDWriteFactory::CreateTextFormat failed (typewriter)";
            return false;
        }
    }

    // --- WIC software render target (see header) --------------------------------------------
    HRESULT comHr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool weInitializedCom = (comHr == S_OK || comHr == S_FALSE);
    if (FAILED(comHr) && comHr != RPC_E_CHANGED_MODE)
    {
        outError = "CoInitializeEx failed for text raster";
        return false;
    }

    bool ok = [&]() -> bool
    {
        ComPtr<IWICImagingFactory> wicFactory;
        if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                IID_PPV_ARGS(&wicFactory))))
        {
            outError = "CoCreateInstance(WICImagingFactory) failed for text raster";
            return false;
        }
        ComPtr<IWICBitmap> wicBitmap;
        if (FAILED(wicFactory->CreateBitmap(static_cast<UINT>(W), static_cast<UINT>(H),
                GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &wicBitmap)))
        {
            outError = "IWICImagingFactory::CreateBitmap failed for text raster";
            return false;
        }

        D2D1_RENDER_TARGET_PROPERTIES rtProps = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
        ComPtr<ID2D1RenderTarget> rt;
        if (FAILED(d2dFactory_->CreateWicBitmapRenderTarget(wicBitmap.Get(), rtProps, &rt)))
        {
            outError = "CreateWicBitmapRenderTarget failed for text raster";
            return false;
        }
        // Subpixel/antialiasing on, matching CGContext's antialias + font-smoothing (swift:57-62).
        rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        rt->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);

        ComPtr<ID2D1SolidColorBrush> fillBrush, strokeBrush, shadowBrush, bgBrush, highlightBrush;
        rt->BeginDraw();
        rt->Clear(D2D1::ColorF(0, 0, 0, 0)); // transparent — text over nothing (composited later)

        rt->CreateSolidColorBrush(ToColorF(clip.style.color), &fillBrush);
        if (clip.style.borderEnabled)
        {
            rt->CreateSolidColorBrush(ToColorF(clip.style.borderColor), &strokeBrush);
        }
        if (clip.style.shadowEnabled)
        {
            rt->CreateSolidColorBrush(ToColorF(clip.style.shadowColor), &shadowBrush);
        }

        // Background box fill — drawBox (swift:405-410). Same rect the Swift boxRect describes,
        // expressed y-down. Always drawn first (under the glyphs/shadow), exactly like
        // beginContext — but WHERE it's filled depends on mode. On the Mac, drawBox runs before
        // the cached base image is produced, so applyEntrance's scale/dy CGAffineTransform
        // (TextFrameRenderer.swift:97-107) moves the box together with the glyphs for
        // fadeIn/popIn/slideUp. PerWord/Typewriter never apply a whole-image transform, so the box
        // stays static there. drawBox() is called at the right point for each mode below: here
        // (identity) for PerWord/Typewriter, inside the Entrance case (under its pivot/scale/dy
        // transform) for Entrance.
        if (clip.style.backgroundEnabled)
        {
            rt->CreateSolidColorBrush(ToColorF(clip.style.backgroundColor), &bgBrush);
        }
        D2D1_RECT_F box = D2D1::RectF(static_cast<float>(boxLeft), static_cast<float>(boxTop),
            static_cast<float>(boxLeft + boxWidth), static_cast<float>(boxTop + boxHeight));
        auto drawBox = [&]()
        {
            if (bgBrush)
            {
                rt->FillRectangle(box, bgBrush.Get());
            }
        };
        if (mode != TextAnimator::RenderMode::Entrance)
        {
            drawBox();
        }

        // Shadow offset in y-down DIPs. CG sets it y-up as (offsetX*scale, -offsetY*scale)
        // (applyShadow, swift:412-420); converting that displacement to y-down flips the y sign
        // again, giving (offsetX*scale, offsetY*scale). Blur is approximated as a hard offset here
        // (see header). scale = H/1080 (swift:414).
        float shadowDx = static_cast<float>(clip.style.shadowOffsetX * scale);
        float shadowDy = static_cast<float>(clip.style.shadowOffsetY * scale);
        float strokeWidth = static_cast<float>(fontSize * kGlyphBorderStrokeWidthPct / 100.0);

        GlyphOutlineRenderer renderer(d2dFactory_.Get(), rt.Get(), fillBrush.Get(),
            strokeBrush.Get(), shadowBrush.Get(), clip.style.borderEnabled, strokeWidth,
            clip.style.shadowEnabled, shadowDx, shadowDy);

        switch (mode)
        {
        case TextAnimator::RenderMode::Entrance:
        {
            TextAnimator::ClipState st = TextAnimator::ClipEntry(clip.animation, rel);
            float cx = static_cast<float>(boxLeft + boxWidth / 2.0);
            float cy = static_cast<float>(boxTop + boxHeight / 2.0);
            rt->SetTransform(PivotScaleDy(cx, cy, static_cast<float>(st.scale),
                static_cast<float>(st.dy * H)));
            // Box drawn here, under the same transform as the glyphs below it, so it scales/slides
            // together with the text exactly like the Mac's single cached-image transform does.
            drawBox();
            // Draw at the box's top-left in y-down; text flows down, wraps at boxWidth, aligned
            // per format — the same top-anchored, box-width-wrapped layout the CoreText
            // framesetter path produces (swift:76-80).
            layout->Draw(nullptr, &renderer, static_cast<float>(boxLeft), static_cast<float>(boxTop));
            rt->SetTransform(D2D1::Matrix3x2F::Identity());
            break;
        }
        case TextAnimator::RenderMode::PerWord:
        {
            for (size_t i = 0; i < tokens.size(); ++i)
            {
                TextAnimator::WordState st = TextAnimator::WordStateFor(
                    clip.animation, tokenTimings[i], rel, clip.style.color);
                if (st.opacity <= 0.0)
                {
                    continue; // matches renderPerWord's `guard st.opacity > 0 else { continue }`
                }

                DWRITE_HIT_TEST_METRICS hitMetrics[4]{};
                UINT32 actualHitCount = 0;
                HRESULT hth = layout->HitTestTextRange(tokens[i].utf16Start, tokens[i].utf16Length,
                    static_cast<FLOAT>(boxLeft), static_cast<FLOAT>(boxTop),
                    hitMetrics, 4, &actualHitCount);
                if (FAILED(hth) || actualHitCount == 0)
                {
                    continue; // token fell outside the laid-out text (shouldn't happen)
                }
                const DWRITE_HIT_TEST_METRICS& wr = hitMetrics[0];

                std::wstring wordText = contentWide.substr(tokens[i].utf16Start, tokens[i].utf16Length);
                ComPtr<IDWriteTextLayout> wordLayout;
                if (FAILED(dwriteFactory_->CreateTextLayout(wordText.c_str(),
                        static_cast<UINT32>(wordText.size()), wordFormat.Get(), 10000.0f,
                        static_cast<float>(fontSize) * 4.0f, &wordLayout)))
                {
                    continue;
                }

                fillBrush->SetColor(ToColorF(st.color));
                fillBrush->SetOpacity(static_cast<float>(st.opacity));
                if (strokeBrush) strokeBrush->SetOpacity(static_cast<float>(st.opacity));
                if (shadowBrush) shadowBrush->SetOpacity(static_cast<float>(st.opacity));

                float cx = wr.left + wr.width / 2.0f;
                float cy = wr.top + wr.height / 2.0f;
                // dy is a fraction of FONT SIZE here (WordState convention), not render height —
                // matches renderPerWord's `ctx.translateBy(x: 0, y: -st.dy * fontSize)` (swift:160).
                rt->SetTransform(PivotScaleDy(cx, cy, static_cast<float>(st.scale),
                    static_cast<float>(st.dy * fontSize)));

                if (st.bgColor.has_value() && st.bgColor->a > 0.001)
                {
                    if (!highlightBrush)
                    {
                        rt->CreateSolidColorBrush(ToColorF(*st.bgColor), &highlightBrush);
                    }
                    highlightBrush->SetColor(ToColorF(*st.bgColor));
                    highlightBrush->SetOpacity(static_cast<float>(st.opacity));
                    float padX = static_cast<float>(fontSize * 0.18);
                    float padY = static_cast<float>(fontSize * 0.10);
                    D2D1_ROUNDED_RECT rr{};
                    rr.rect = D2D1::RectF(wr.left - padX, wr.top - padY,
                        wr.left + wr.width + padX, wr.top + wr.height + padY);
                    rr.radiusX = rr.radiusY = static_cast<float>(fontSize * 0.12);
                    rt->FillRoundedRectangle(rr, highlightBrush.Get());
                }

                wordLayout->Draw(nullptr, &renderer, wr.left, wr.top);
                rt->SetTransform(D2D1::Matrix3x2F::Identity());
            }
            break;
        }
        case TextAnimator::RenderMode::Typewriter:
        {
            TextAnimator::TypewriterState tw =
                TextAnimator::Typewriter(tokens, tokenTimings, rel, clip.durationFrames);
            uint32_t visLen = std::min<uint32_t>(tw.visibleUtf16Length,
                static_cast<uint32_t>(contentWide.size()));
            std::wstring visible = contentWide.substr(0, visLen);
            if (tw.caretOn)
            {
                visible += L"|";
            }
            if (!visible.empty())
            {
                ComPtr<IDWriteTextLayout> visLayout;
                if (SUCCEEDED(dwriteFactory_->CreateTextLayout(visible.c_str(),
                        static_cast<UINT32>(visible.size()), typewriterFormat.Get(),
                        static_cast<float>(boxWidth), static_cast<float>(boxMaxHeight), &visLayout)))
                {
                    visLayout->Draw(nullptr, &renderer, static_cast<float>(boxLeft), static_cast<float>(boxTop));
                }
            }
            break;
        }
        }

        HRESULT endHr = rt->EndDraw();
        if (FAILED(endHr))
        {
            outError = "ID2D1RenderTarget::EndDraw failed for text raster";
            return false;
        }

        // Read back the premultiplied BGRA and UNpremultiply to straight alpha (mirrors
        // composedTextLayer's `.unpremultiplyingAlpha()`), folding the whole-clip entrance fade
        // into alpha for Entrance mode (TextAnimator.applyEntrance scales the premultiplied
        // image's alpha, swift:108-116); per-word/typewriter already baked their own alpha into
        // each draw call, so finalAlphaScale is 1.0 there.
        ComPtr<IWICBitmapLock> lock;
        WICRect rect{0, 0, W, H};
        if (FAILED(wicBitmap->Lock(&rect, WICBitmapLockRead, &lock)))
        {
            outError = "IWICBitmap::Lock failed for text raster";
            return false;
        }
        UINT stride = 0, bufferSize = 0;
        BYTE* src = nullptr;
        lock->GetStride(&stride);
        lock->GetDataPointer(&bufferSize, &src);
        if (!src)
        {
            outError = "IWICBitmapLock::GetDataPointer returned null";
            return false;
        }

        out.width = W;
        out.height = H;
        out.strideBytes = W * 4;
        out.bgra.resize(static_cast<size_t>(out.strideBytes) * H);
        bool anyCoverage = false;
        for (int32_t y = 0; y < H; ++y)
        {
            const BYTE* srcRow = src + static_cast<size_t>(y) * stride;
            uint8_t* dstRow = out.bgra.data() + static_cast<size_t>(y) * out.strideBytes;
            for (int32_t x = 0; x < W; ++x)
            {
                const BYTE* p = srcRow + static_cast<size_t>(x) * 4; // premultiplied B,G,R,A
                uint32_t a = p[3];
                if (a == 0)
                {
                    dstRow[x * 4 + 0] = 0;
                    dstRow[x * 4 + 1] = 0;
                    dstRow[x * 4 + 2] = 0;
                    dstRow[x * 4 + 3] = 0;
                    continue;
                }
                anyCoverage = true;
                auto unpremult = [a](uint32_t c) -> uint8_t {
                    uint32_t v = (c * 255u + a / 2u) / a;
                    return static_cast<uint8_t>(v > 255u ? 255u : v);
                };
                dstRow[x * 4 + 0] = unpremult(p[0]);
                dstRow[x * 4 + 1] = unpremult(p[1]);
                dstRow[x * 4 + 2] = unpremult(p[2]);
                double fadedA = a * finalAlphaScale;
                dstRow[x * 4 + 3] = static_cast<uint8_t>(std::clamp(fadedA + 0.5, 0.0, 255.0));
            }
        }
        lock.Reset();
        if (!anyCoverage)
        {
            out = Raster{}; // nothing drew (e.g. all-whitespace after wrap) — skip compositing
        }
        return true;
    }();

    if (weInitializedCom)
    {
        CoUninitialize();
    }
    return ok;
}
