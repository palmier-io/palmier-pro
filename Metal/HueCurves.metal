#include <CoreImage/CoreImage.h>
using namespace metal;

// Per-pixel hue curves. Sampled at the pixel's hue from a 256-wide 1D LUT
// (R=Δhue, G=satScale, B=Δlum). Sat-gated so near-grays stay neutral. Display-space HSV.
// Compiled to a CI kernel by the MetalCIKernelPlugin (xcrun metal -fcikernel).

static float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}

static float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
}

extern "C" float4 hueCurves(coreimage::sampler img, coreimage::sampler lut) {
    float4 s = img.sample(img.coord());
    float3 hsv = rgb2hsv(saturate(s.rgb));
    float4 L = lut.sample(lut.transform(float2(hsv.x * 256.0, 0.5)));
    float gate = smoothstep(0.04, 0.18, hsv.y);
    float h2 = fract(hsv.x + L.r * gate);
    float s2 = saturate(hsv.y * (1.0 + L.g * gate));
    float v2 = saturate(hsv.z + L.b * gate);
    return float4(hsv2rgb(float3(h2, s2, v2)), s.a);
}
