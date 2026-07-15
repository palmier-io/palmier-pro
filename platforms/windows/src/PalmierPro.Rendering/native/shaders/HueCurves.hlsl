// Exact port of Metal/HueCurves.metal's `hueCurves(sampler, lut)` (incl. rgb2hsv/hsv2rgb).
// General-kernel I/O convention — see Vignette.hlsl's header comment.
//
// LUT sampling convention: HueCurveKernel.buildLUT (Swift) samples at bin-center
// hue_i = (i+0.5)/w, w=256 — which is ALREADY a valid D3D texel-center UV coordinate for
// texel i (D3D texel i's center is at (i+0.5)/w by definition), so `uv = hue` directly
// round-trips exactly at every authored sample point, unlike GradeCurves.hlsl's edge-anchored
// LUT (see that file's header comment for why the two conventions differ and the same
// "best-effort, not bit-exact vs. Core Image" caveat).
#include "Common.hlsl"

Texture2D<float4> SourceTex : register(t0);
Texture2D<float4> LutTex : register(t1); // 256x1, R=dHue, G=satScale, B=dLum

SamplerState PointClamp : register(s0);
SamplerState LinearWrapLut : register(s1); // WRAP addressing — hue is cyclic

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float3 Rgb2Hsv(float3 c)
{
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

float3 Hsv2Rgb(float3 c)
{
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 s = SourceTex.Sample(PointClamp, input.uv);
    float3 hsv = Rgb2Hsv(saturate(s.rgb));

    float4 L = LutTex.Sample(LinearWrapLut, float2(frac(hsv.x), 0.5));
    float gate = smoothstep(0.04, 0.18, hsv.y);
    float h2 = frac(hsv.x + L.r * gate);
    float s2 = saturate(hsv.y * (1.0 + L.g * gate));
    float v2 = saturate(hsv.z + L.b * gate);

    return float4(Hsv2Rgb(float3(h2, s2, v2)), s.a);
}
