// Exact port of Metal/Glow.metal's `glowComposite(sampler img, sampler glow, intensity)` —
// screen-blends the blurred bright-pass back over the source. General-kernel I/O convention
// (direct premultiplied read/write) — see Vignette.hlsl's header comment.
Texture2D<float4> SourceTex : register(t0);
Texture2D<float4> GlowTex : register(t1); // blurred glowBright output, natural resolution
SamplerState PointClamp : register(s0);

cbuffer Params : register(b0)
{
    float Intensity;
    float3 _Pad;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 s = SourceTex.Sample(PointClamp, input.uv);
    float3 g = saturate(GlowTex.Sample(PointClamp, input.uv).rgb * Intensity);
    return float4(1.0 - (1.0 - s.rgb) * (1.0 - g), s.a);
}
