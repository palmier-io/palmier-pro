// Shared HLSL helpers, resolved via `#include "Common.hlsl"` by GpuCompositor's ID3DInclude
// handler (shaders directory, next to PalmierEngine.dll — see GpuCompositor.cpp). Two families:
//   1. Premultiply/unpremultiply + sRGB linearize/delinearize — the plan's "Color pipeline"
//      seam. Working format is GAMMA-ENCODED premultiplied RGBA (R16G16B16A16_FLOAT); linearize/
//      delinearize wrap ONLY the effects EffectRegistry.h flags linearizes:true (none of the 11
//      ported kernels today — see that file's header comment).
//   2. PDF (ISO 32000-1 §11.3.5) separable + non-separable blend-mode formulas, used by
//      Composite.hlsl for the per-track blend pass. Order of the `ApplyBlend` dispatch matches
//      BlendMode.swift's case order exactly (0=normal is handled by the caller, not here).

static const float kAlphaEpsilon = 1e-5;

float3 UnpremultiplyRgb(float4 premultiplied)
{
    float a = max(premultiplied.a, kAlphaEpsilon);
    return premultiplied.rgb / a;
}

float4 Premultiply(float3 straightRgb, float alpha)
{
    return float4(straightRgb * alpha, alpha);
}

// CISRGBToneCurveToLinear / CILinearToSRGBToneCurve — the sRGB EOTF, applied only around
// effects flagged linearizes:true in EffectRegistry.h (currently none of the 11 ported kernels).
float3 LinearizeSrgb(float3 c)
{
    float3 lo = c / 12.92;
    float3 hi = pow(max((c + 0.055) / 1.055, 0.0), 2.4);
    return c <= 0.04045 ? lo : hi;
}

float3 DelinearizeSrgb(float3 c)
{
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055;
    return c <= 0.0031308 ? lo : hi;
}

// ---- PDF separable blend functions B(Cb, Cs) — straight (unpremultiplied) color in/out ----

float3 BlendMultiply(float3 cb, float3 cs) { return cb * cs; }
float3 BlendScreen(float3 cb, float3 cs) { return cb + cs - cb * cs; }
float3 BlendDarken(float3 cb, float3 cs) { return min(cb, cs); }
float3 BlendLighten(float3 cb, float3 cs) { return max(cb, cs); }

float BlendColorDodgeChannel(float cb, float cs)
{
    if (cb <= 0.0) return 0.0;
    if (cs >= 1.0) return 1.0;
    return min(1.0, cb / (1.0 - cs));
}
float3 BlendColorDodge(float3 cb, float3 cs)
{
    return float3(BlendColorDodgeChannel(cb.r, cs.r), BlendColorDodgeChannel(cb.g, cs.g), BlendColorDodgeChannel(cb.b, cs.b));
}

float BlendColorBurnChannel(float cb, float cs)
{
    if (cb >= 1.0) return 1.0;
    if (cs <= 0.0) return 0.0;
    return 1.0 - min(1.0, (1.0 - cb) / cs);
}
float3 BlendColorBurn(float3 cb, float3 cs)
{
    return float3(BlendColorBurnChannel(cb.r, cs.r), BlendColorBurnChannel(cb.g, cs.g), BlendColorBurnChannel(cb.b, cs.b));
}

float3 BlendHardLight(float3 cb, float3 cs)
{
    float3 mul = BlendMultiply(cb, saturate(2.0 * cs));
    float3 scr = BlendScreen(cb, saturate(2.0 * cs - 1.0));
    return float3(
        cs.r <= 0.5 ? mul.r : scr.r,
        cs.g <= 0.5 ? mul.g : scr.g,
        cs.b <= 0.5 ? mul.b : scr.b);
}

// Overlay(Cb,Cs) = HardLight(Cs,Cb) per the PDF spec.
float3 BlendOverlay(float3 cb, float3 cs) { return BlendHardLight(cs, cb); }

float SoftLightD(float x) { return x <= 0.25 ? ((16.0 * x - 12.0) * x + 4.0) * x : sqrt(x); }
float BlendSoftLightChannel(float cb, float cs)
{
    if (cs <= 0.5)
    {
        return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb);
    }
    return cb + (2.0 * cs - 1.0) * (SoftLightD(cb) - cb);
}
float3 BlendSoftLight(float3 cb, float3 cs)
{
    return float3(BlendSoftLightChannel(cb.r, cs.r), BlendSoftLightChannel(cb.g, cs.g), BlendSoftLightChannel(cb.b, cs.b));
}

float3 BlendDifference(float3 cb, float3 cs) { return abs(cb - cs); }
float3 BlendExclusion(float3 cb, float3 cs) { return cb + cs - 2.0 * cb * cs; }

// ---- PDF non-separable helpers (§11.3.5.3) ----

float Lum(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }

float3 ClipColor(float3 c)
{
    float l = Lum(c);
    float n = min(c.r, min(c.g, c.b));
    float x = max(c.r, max(c.g, c.b));
    if (n < 0.0)
    {
        c = l + (c - l) * (l / max(l - n, kAlphaEpsilon));
    }
    if (x > 1.0)
    {
        c = l + (c - l) * ((1.0 - l) / max(x - l, kAlphaEpsilon));
    }
    return c;
}

float3 SetLum(float3 c, float l)
{
    float d = l - Lum(c);
    return ClipColor(c + d);
}

float Sat(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }

// Ported directly from the PDF spec's SetSat pseudocode (sort into Cmax/Cmid/Cmin roles by
// VALUE comparison — HLSL has no by-reference sort, so ties resolve by whichever comparison
// matches first; degenerate all-equal input intentionally yields (0,0,0), per spec).
float3 SetSat(float3 c, float s)
{
    float cmax = max(c.r, max(c.g, c.b));
    float cmin = min(c.r, min(c.g, c.b));
    float3 result = float3(0, 0, 0);
    if (cmax > cmin)
    {
        float cmid = c.r + c.g + c.b - cmax - cmin;
        float mid = (cmid - cmin) * s / (cmax - cmin);
        if (c.r == cmax)
        {
            result.r = s;
            if (c.g == cmin) { result.g = 0.0; result.b = mid; }
            else { result.b = 0.0; result.g = mid; }
        }
        else if (c.g == cmax)
        {
            result.g = s;
            if (c.r == cmin) { result.r = 0.0; result.b = mid; }
            else { result.b = 0.0; result.r = mid; }
        }
        else
        {
            result.b = s;
            if (c.r == cmin) { result.r = 0.0; result.g = mid; }
            else { result.g = 0.0; result.r = mid; }
        }
    }
    return result;
}

float3 BlendHue(float3 cb, float3 cs) { return SetLum(SetSat(cs, Sat(cb)), Lum(cb)); }
float3 BlendSaturation(float3 cb, float3 cs) { return SetLum(SetSat(cb, Sat(cs)), Lum(cb)); }
float3 BlendColorMode(float3 cb, float3 cs) { return SetLum(cs, Lum(cb)); }
float3 BlendLuminosity(float3 cb, float3 cs) { return SetLum(cb, Lum(cs)); }

// mode: BlendMode.swift raw-value index (0=normal ... 15=luminosity) — see Composite.hlsl's
// header comment and GpuCompositor.cpp's BlendModeToIndex for the shared mapping. 0/unrecognized
// falls through to `cs` (never called for mode 0 by Composite.hlsl, which fast-paths Normal).
float3 ApplyBlend(int mode, float3 cb, float3 cs)
{
    switch (mode)
    {
        case 1: return BlendDarken(cb, cs);
        case 2: return BlendMultiply(cb, cs);
        case 3: return BlendColorBurn(cb, cs);
        case 4: return BlendLighten(cb, cs);
        case 5: return BlendScreen(cb, cs);
        case 6: return BlendColorDodge(cb, cs);
        case 7: return BlendOverlay(cb, cs);
        case 8: return BlendSoftLight(cb, cs);
        case 9: return BlendHardLight(cb, cs);
        case 10: return BlendDifference(cb, cs);
        case 11: return BlendExclusion(cb, cs);
        case 12: return BlendHue(cb, cs);
        case 13: return BlendSaturation(cb, cs);
        case 14: return BlendColorMode(cb, cs);
        case 15: return BlendLuminosity(cb, cs);
        default: return cs;
    }
}
