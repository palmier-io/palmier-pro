// Exact port of Metal/HighlightsShadows.metal's `highlightsShadows(sample_t, highlights,
// shadows)`. ColorKernel I/O convention (unpremultiplied) — see Levels.hlsl's header comment.
#include "Common.hlsl"

Texture2D<float4> SourceTex : register(t0);
SamplerState LinearClamp : register(s0);

cbuffer Params : register(b0)
{
    float Highlights;
    float Shadows;
    float2 _Pad;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 premult = SourceTex.Sample(LinearClamp, input.uv);
    float3 rgb = UnpremultiplyRgb(premult);

    float y = dot(saturate(rgb), float3(0.2126, 0.7152, 0.0722));
    float hi = y * y * y;
    float lo = (1.0 - y) * (1.0 - y) * (1.0 - y);
    float dY = (Highlights * hi + Shadows * lo) * 0.5;
    rgb = saturate(rgb + dY);

    return Premultiply(rgb, premult.a);
}
