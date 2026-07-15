// Exact port of Metal/Glow.metal's `glowBright(sample_t, threshold, warmth)`. ColorKernel I/O
// convention (Swift loads it via `CIKernelLoader.colorKernel` — unpremultiplied) — see
// Levels.hlsl's header comment. Output feeds Blur.hlsl's two-pass Gaussian, then
// GlowComposite.hlsl.
#include "Common.hlsl"

Texture2D<float4> SourceTex : register(t0);
SamplerState LinearClamp : register(s0);

cbuffer Params : register(b0)
{
    float Threshold;
    float Warmth;
    float2 _Pad;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 premult = SourceTex.Sample(LinearClamp, input.uv);
    float3 rgb = UnpremultiplyRgb(premult);

    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float3 hi = rgb * smoothstep(Threshold, 1.0, y);
    float3 warm = hi * float3(1.0, 0.7, 0.45);
    rgb = lerp(hi, warm, Warmth);

    return Premultiply(rgb, premult.a);
}
