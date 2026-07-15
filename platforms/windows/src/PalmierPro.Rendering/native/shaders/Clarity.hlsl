// Exact port of Metal/Clarity.metal's `clarityHaze(sampler img, sampler blurred, clarity,
// dehaze)`. General-kernel I/O convention (direct premultiplied read/write) — see
// Vignette.hlsl's header comment. `blurred` is produced by Blur.hlsl at
// radius = max(natWidth,natHeight)/40 (GpuCompositor.cpp), matching ClarityKernel.swift.
Texture2D<float4> SourceTex : register(t0);
Texture2D<float4> BlurredTex : register(t1);
SamplerState PointClamp : register(s0);

cbuffer Params : register(b0)
{
    float Clarity;
    float Dehaze;
    float2 _Pad;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 s = SourceTex.Sample(PointClamp, input.uv);
    float3 b = BlurredTex.Sample(PointClamp, input.uv).rgb;

    float3 rgb = s.rgb + (s.rgb - b) * Clarity;
    if (Dehaze != 0.0)
    {
        float dark = min(s.rgb.r, min(s.rgb.g, s.rgb.b));
        float w = Dehaze * (0.5 + 0.5 * smoothstep(0.05, 0.5, dark));
        rgb += (s.rgb - b) * (w * 0.6);
        rgb = lerp(float3(0.45, 0.45, 0.45), rgb, 1.0 + w * 0.45);
        float yy = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = lerp(float3(yy, yy, yy), rgb, 1.0 + w * 0.5);
    }

    return float4(saturate(rgb), s.a);
}
