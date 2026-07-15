#pragma once

#include <string>
#include <vector>

// Native mirror of Sources/PalmierPro/Compositing/EffectRegistry.swift, restricted to the
// 11 custom Metal-kernel effects (E3's port scope — see Metal/*.metal). The other
// EffectRegistry.swift entries (color.exposure, color.contrast, color.saturation,
// color.temperature, color.vibrance, blur.gaussian, blur.sharpen, blur.noiseReduction,
// blur.motion) are Core Image *filter* wrappers (CIExposureAdjust, CIColorControls, ...),
// not one of the 11 Metal kernels named in the plan's "Effect kernel port table" — out of
// scope for this native table. Every field/line reference below points at the exact
// EffectRegistry.swift source that was ported.
//
// `linearizes`: none of the 11 kernel effects set `linearizes: true` in EffectRegistry.swift
// (only color.exposure does, and that's out of scope per above) — so every entry here is
// `linearizes = false`. The sRGB linearize/delinearize HLSL helpers still exist
// (shaders/Common.hlsl: LinearizeSrgb/DelinearizeSrgb), but GpuCompositor does NOT consult this
// flag today (see GpuCompositor.h's header comment) — it is carried for forward-compatibility
// with EffectRegistry.swift only. A future linearizes:true kernel port must add the wrap around
// its own pass explicitly; it will not happen automatically.

enum class EffectKernel
{
    HighlightsShadows, // EffectRegistry.swift:128 "color.highlightsShadows" -> Metal/HighlightsShadows.metal
    Levels,             // EffectRegistry.swift:141 "color.blacksWhites"     -> Metal/Levels.metal
    Wheels,             // EffectRegistry.swift:161 "color.wheels"          -> Metal/Wheels.metal
    HueCurves,          // EffectRegistry.swift:181 "color.hueCurves"       -> Metal/HueCurves.metal
    LutTetra,           // EffectRegistry.swift:192 "color.lut"             -> Metal/LUTTetra.metal
    GradeCurves,        // EffectRegistry.swift:205 "color.curves"          -> Metal/GradeCurves.metal
    Clarity,            // EffectRegistry.swift:316 "detail.clarity"        -> Metal/Clarity.metal
    ChromaKey,          // EffectRegistry.swift:329 "key.chroma"            -> Metal/ChromaKey.metal
    Grain,              // EffectRegistry.swift:275 "stylize.grain"         -> Metal/Grain.metal
    Vignette,           // EffectRegistry.swift:285 "stylize.vignette"      -> Metal/Vignette.metal
    Glow,               // EffectRegistry.swift:299 "stylize.glow"          -> Metal/Glow.metal
};

// Mirrors whether the Swift kernel was loaded as a CIColorKernel (`CIKernelLoader.colorKernel`,
// unpremultiplied RGB in/out — Levels/HighlightsShadows/Wheels/ChromaKey) or a general CIKernel
// (`CIKernelLoader.kernel`, operates on CI's default premultiplied samples — Vignette/Grain/
// GradeCurves/HueCurves/LUTTetra/Glow/Clarity). GpuCompositor wraps ColorKernel-style passes
// with an unpremultiply-before/premultiply-after step (inline in the HLSL, see each .hlsl file);
// GeneralKernel-style passes read/write the working premultiplied fp16 texture directly.
enum class EffectKernelIoConvention
{
    ColorKernel,   // unpremultiplied I/O
    GeneralKernel, // premultiplied I/O (matches storage directly)
};

struct EffectParamSpecNative
{
    std::string key;
    double defaultValue = 0.0;
    double rangeMin = 0.0;
    double rangeMax = 1.0;
};

struct EffectDescriptorNative
{
    std::string id; // Effect.type raw string
    EffectKernel kernel;
    EffectKernelIoConvention ioConvention;
    bool linearizes = false;
    std::vector<EffectParamSpecNative> params; // numeric params only; string params (curves/path) handled separately
};

namespace EffectRegistry
{
    // nullptr if `type` isn't one of the 11 ported kernel effects.
    const EffectDescriptorNative* Find(const std::string& type);
}
