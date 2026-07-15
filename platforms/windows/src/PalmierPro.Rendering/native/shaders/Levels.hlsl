// Exact port of Metal/Levels.metal's `levels(sample_t, blacks, whites)`. Loaded on the Swift
// side via CIColorKernel (unpremultiplied I/O) — see EffectRegistry.h's
// EffectKernelIoConvention::ColorKernel — so this pass unpremultiplies, applies the identical
// math, then re-premultiplies with the (untouched) source alpha.
#include "Common.hlsl"

Texture2D<float4> SourceTex : register(t0);
SamplerState LinearClamp : register(s0);

cbuffer LevelsParams : register(b0)
{
    float Blacks;
    float Whites;
    float2 _Pad;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 premult = SourceTex.Sample(LinearClamp, input.uv);
    float3 rgb = UnpremultiplyRgb(premult);

    float bp = -Blacks * 0.4;
    float wp = 1.0 - Whites * 0.4;
    rgb = saturate((rgb - bp) / max(0.05, wp - bp));

    return Premultiply(rgb, premult.a);
}
