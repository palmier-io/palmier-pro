// Exact port of Metal/Wheels.metal's `wheels(sample_t, lift, gain, invGamma)`. `lift`/`gain`/
// `invGamma` are pre-computed native-side (ColorWheels.coefficients, ported verbatim in
// GpuCompositor.cpp) from the 9 raw lift/gamma/gain_{x,y,m} params — mirrors WheelsKernel.swift
// exactly. ColorKernel I/O convention (unpremultiplied) — see Levels.hlsl's header comment.
#include "Common.hlsl"

Texture2D<float4> SourceTex : register(t0);
SamplerState LinearClamp : register(s0);

cbuffer Params : register(b0)
{
    float3 Lift;
    float _Pad0;
    float3 Gain;
    float _Pad1;
    float3 InvGamma;
    float _Pad2;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 premult = SourceTex.Sample(LinearClamp, input.uv);
    float3 rgb = UnpremultiplyRgb(premult);

    float3 lit = max(rgb * (1.0 - Lift) + Lift, float3(0.0, 0.0, 0.0)) * Gain;
    rgb = saturate(pow(max(lit, 0.0), InvGamma));

    return Premultiply(rgb, premult.a);
}
