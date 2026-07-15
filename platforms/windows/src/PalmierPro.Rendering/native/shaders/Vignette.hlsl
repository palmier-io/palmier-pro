// Exact port of Metal/Vignette.metal's `vignette(sampler, rect, amount, midpoint, roundness,
// feather, destination)`. General-kernel I/O convention (operates directly on the premultiplied
// working texture — see EffectRegistry.h's EffectKernelIoConvention::GeneralKernel; a pure
// multiplicative RGB scale commutes with premultiplication, so no unpremultiply/premultiply
// wrap is needed here, unlike the ColorKernel-style effects). `rect` = the clip's own natural
// pixel extent (0,0,natWidth,natHeight), matching Swift's `image.extent` argument exactly.
Texture2D<float4> SourceTex : register(t0);
SamplerState PointClamp : register(s0);

cbuffer Params : register(b0)
{
    float4 Rect; // x, y, width, height (pixels, natural resolution)
    float Amount;
    float Midpoint;
    float Roundness;
    float Feather;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 s = SourceTex.Sample(PointClamp, input.uv);
    float2 destCoord = input.uv * Rect.zw + Rect.xy;

    float2 center = Rect.xy + Rect.zw * 0.5;
    float2 halfSize = max(Rect.zw * 0.5, float2(1.0, 1.0));
    float2 d = (destCoord - center) / halfSize;
    float p = lerp(6.0, 2.0, (Roundness + 1.0) * 0.5);
    float dist = pow(pow(abs(d.x), p) + pow(abs(d.y), p), 1.0 / p);
    float v = smoothstep(Midpoint, Midpoint + Feather * 1.5 + 0.05, dist);

    return float4(saturate(s.rgb * (1.0 + Amount * v)), s.a);
}
