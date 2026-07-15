// Exact port of Metal/Grain.metal's `grain(sampler, amount, size, frame, destination)`.
// General-kernel I/O convention — see Vignette.hlsl's header comment.
Texture2D<float4> SourceTex : register(t0);
SamplerState PointClamp : register(s0);

cbuffer Params : register(b0)
{
    float Amount;
    float Size;
    float Frame;
    float _Pad;
    float2 TextureSizePixels; // natural resolution, for destCoord reconstruction
    float2 _Pad2;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float Hash13(float3 p3)
{
    p3 = frac(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 s = SourceTex.Sample(PointClamp, input.uv);
    float2 destCoord = input.uv * TextureSizePixels;
    float2 co = destCoord / max(Size, 0.5);
    float n = Hash13(float3(co, Frame)) - 0.5;
    float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float lumaMask = 4.0 * y * (1.0 - y);
    return float4(saturate(s.rgb + n * Amount * 0.35 * lumaMask), s.a);
}
