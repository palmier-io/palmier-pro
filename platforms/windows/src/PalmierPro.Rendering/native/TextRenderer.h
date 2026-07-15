#pragma once

#include "TimelineSnapshot.h"

#include <d2d1.h>
#include <dwrite_3.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>
#include <vector>

// Software (WIC-backed) Direct2D/DirectWrite text rasterizer — E4's "Text/titles" deliverable.
// Faithful mirror of Compositing/TextFrameRenderer.swift (TextFrameRenderer.image) plus the
// pieces of Compositing/FrameRenderer.swift (composedTextLayer) and Models/TextStyle.swift /
// Models/TextLayout.swift the render path reads. Cited Swift lines appear inline in the .cpp
// next to the math they mirror.
//
// WHY A WIC SOFTWARE RENDER TARGET (not a D2D device on the engine's shared D3D11 device):
//   1. The Mac's own text path is a CPU CGContext raster (TextFrameRenderer.beginContext creates
//      a CGBitmapContext, not a Metal/GPU surface) — a software D2D target is the faithful
//      structural mirror, not a downgrade.
//   2. D2D1CreateDevice / CreateBitmapFromDxgiSurface interop requires the D3D11 device to carry
//      D3D11_CREATE_DEVICE_BGRA_SUPPORT. EngineSession's shared device (EngineSession.cpp's
//      D3D11CreateDevice call) is created WITHOUT that flag, and that file is outside this slice's
//      ownership — so a GPU D2D target on the shared device is not available here without an
//      out-of-slice change.
//   3. The compositor already ingests every clip from a CPU BGRA buffer (DecodedSourceFrame), so a
//      CPU text raster feeds the existing upload -> Ingest.hlsl -> composite path with zero new
//      plumbing — GpuCompositor treats the text raster exactly like a decoded clip frame.
//
// COLOR / ALPHA: the WIC target is 32bppPBGRA (premultiplied, sRGB values used verbatim — no color
// management, matching CustomVideoCompositor's NSNull working space). The raster is UNpremultiplied
// on readback to straight-alpha BGRA8, mirroring composedTextLayer's `.unpremultiplyingAlpha()`
// (FrameRenderer.swift:286) so Ingest.hlsl's straight->premultiplied step lands it identically to a
// decoded clip.
//
// SCOPE (E4 v1): static layout (font/size/color/alignment/word-wrap/anchor), glyph border/stroke,
// background box, drop shadow (hard offset, no blur — see REQUIRED FOLLOW-UP below), whole-clip
// entrance presets (fadeIn/popIn/slideUp — opacity AND the scale/dy geometry, applied as a D2D
// transform pivoted on the box center), the six per-word presets (wordReveal/wordSlide/wordPop/
// wordCycle/highlightPop/highlightBlock), and typewriter (whole-clip character reveal with a
// blinking caret). All animation TIMING/EASING math (the per-frame ClipState/WordState evaluation,
// word tokenization, and wordTimings<->token alignment) lives in TextAnimator.h/.cpp — a pure,
// D2D-free port of Compositing/TextAnimator.swift + the tokenizing helpers in Compositing/
// TextFrameRenderer.swift; this file only turns those per-frame states into draw calls. Per-word
// draws use IDWriteTextLayout::HitTestTextRange against the FULL (wrapped) layout to find each
// token's on-screen box, then render that token as its own small unwrapped layout through the same
// GlyphOutlineRenderer, transformed (scale + dy) around that box's center — the DirectWrite analog
// of TextFrameRenderer.renderPerWord building an independent CTLine per word off the full CTFrame's
// line origins. Opacity keyframes + fades + blend mode are applied by GpuCompositor's composite
// pass, not here (identical to any other clip).
//
// REQUIRED FOLLOW-UP (E4, not yet scheduled): drop shadow has no blur. GlyphOutlineRenderer
// (TextRenderer.cpp, DrawGlyphRun's shadow branch) fills the glyph outline a second time at a hard
// pixel offset with no softening, while the Mac's applyShadow (TextFrameRenderer.swift:412-420)
// sets CGContextSetShadow with blur = max(0, shadow.blur * scale) (default blur = 6) for a soft
// shadow. Because TextStyle.Shadow.enabled defaults to true (TextStyle.swift:33), this is not an
// edge case — nearly every default-styled title shows a hard doubled-glyph echo on Windows instead
// of a soft shadow. Two implementation paths, either acceptable:
//   1. ID2D1Effect (CLSID_D2D1GaussianBlur) on a D2D-effect device context — needs its own D3D11
//      device with D3D11_CREATE_DEVICE_BGRA_SUPPORT (see WHY A WIC SOFTWARE RENDER TARGET point 2
//      above for why EngineSession's shared device can't supply this); WARP is fine since this
//      target is already CPU-side.
//   2. A separable blur on the raster: render the shadow into its own W x H layer (skip box/
//      fill/stroke), box-blur it, then D2D1RenderTarget::DrawBitmap it under the normal
//      fill/stroke pass. This can reuse the two-pass separable-Gaussian compute infrastructure
//      already built for Glow/Clarity (native/shaders/Blur.hlsl's BlurHorizontalCS/BlurVerticalCS)
//      instead of writing new blur math, if the shadow layer is uploaded as a texture the same way
//      GpuCompositor already uploads this renderer's text raster.
// Until one of these lands, `shadowBlur` (TimelineSnapshot.h) is parsed but unused here.
class TextRenderer
{
public:
    struct Raster
    {
        std::vector<uint8_t> bgra; // straight (non-premultiplied) alpha, 8-bit BGRA, row-major
        int32_t width = 0;
        int32_t height = 0;
        int32_t strideBytes = 0;
        bool Empty() const { return bgra.empty() || width <= 0 || height <= 0; }
    };

    TextRenderer() = default;
    ~TextRenderer() = default;
    TextRenderer(const TextRenderer&) = delete;
    TextRenderer& operator=(const TextRenderer&) = delete;

    // Rasterizes `clip` at timeline `frame` into a canvasWidth x canvasHeight straight-alpha BGRA
    // raster (same shape as DecodedSourceFrame). Returns true with a populated `out` when there is
    // something to draw; returns true with an EMPTY `out` (out.Empty()) when there is nothing
    // visible (empty content, degenerate canvas, or a fully-faded entrance frame) — the caller
    // simply skips compositing, matching TextFrameRenderer.image returning nil. Returns false only
    // on a hard failure (factory/target/lock error) with outError set.
    bool Render(const SnapshotTextClip& clip, int64_t frame, int32_t canvasWidth, int32_t canvasHeight,
                Raster& out, std::string& outError);

private:
    bool EnsureFactories(std::string& outError);

    Microsoft::WRL::ComPtr<ID2D1Factory> d2dFactory_;
    Microsoft::WRL::ComPtr<IDWriteFactory5> dwriteFactory_;
};
