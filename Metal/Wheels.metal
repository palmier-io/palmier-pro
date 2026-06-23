#include <CoreImage/CoreImage.h>
using namespace metal;

// Lift/Gamma/Gain color wheels, per pixel (replaces the 33³ cube — no quantization).
// Per-channel: clamp(pow(max(0, in·(1−lift) + lift) · gain, invGamma)).
extern "C" float4 wheels(coreimage::sample_t s, float3 lift, float3 gain, float3 invGamma) {
    float3 lit = max(s.rgb * (1.0 - lift) + lift, float3(0.0)) * gain;
    return float4(saturate(pow(lit, invGamma)), s.a);
}
