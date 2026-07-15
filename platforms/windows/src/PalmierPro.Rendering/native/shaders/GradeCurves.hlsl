// Exact port of Metal/GradeCurves.metal's `gradeCurves(sampler, lutCh, lutMaster)`. General-
// kernel I/O convention (direct premultiplied read/write — see Vignette.hlsl's header comment).
//
// LUT sampling convention: GradeCurveKernel.buildLUTs (Swift) samples the curve at
// t_i = i/(w-1) for texel i, w=256, then the Metal kernel looks it up via
// `lut.sample(lut.transform(float2(value*256.0, 0.5)))`. Core Image's `sampler.transform`
// texel-addressing convention isn't independently verifiable outside a live CI runtime (no
// other construct in this codebase relies on it either); this port instead defines its OWN,
// internally-consistent convention against the LUT texture GpuCompositor.cpp builds natively:
// texel i's stored value is v_i = i/(w-1) (mirrors buildLUTs exactly), and the D3D texel-center
// formula `uv = (value*(w-1) + 0.5) / w` maps `value == v_i` exactly onto texel i's center —
// i.e. the LUT round-trips exactly at every one of its 256 authored sample points, with linear
// interpolation in between (matching a linear-filtered sampler). Flagged as a best-effort,
// not bit-exact, port of Core Image's sampler addressing — see the milestone report.
#include "Common.hlsl"

Texture2D<float4> SourceTex : register(t0);
Texture2D<float4> LutChannelsTex : register(t1); // 256x1, R=redCurve, G=greenCurve, B=blueCurve
Texture2D<float4> LutMasterTex : register(t2);   // 256x1, RGB all = masterCurve
SamplerState PointClamp : register(s0);
SamplerState LinearClampLut : register(s1);

static const float kLutWidth = 256.0;

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float LutUv(float value)
{
    return saturate((value * (kLutWidth - 1.0) + 0.5) / kLutWidth);
}

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 s = SourceTex.Sample(PointClamp, input.uv);
    float3 rgb = saturate(s.rgb);

    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float yp = LutMasterTex.Sample(LinearClampLut, float2(LutUv(y), 0.5)).r;
    rgb = (y > 1e-4) ? rgb * min(yp / y, 8.0) : float3(yp, yp, yp);

    float r = LutChannelsTex.Sample(LinearClampLut, float2(LutUv(rgb.r), 0.5)).r;
    float g = LutChannelsTex.Sample(LinearClampLut, float2(LutUv(rgb.g), 0.5)).g;
    float b = LutChannelsTex.Sample(LinearClampLut, float2(LutUv(rgb.b), 0.5)).b;

    return float4(r, g, b, s.a);
}
