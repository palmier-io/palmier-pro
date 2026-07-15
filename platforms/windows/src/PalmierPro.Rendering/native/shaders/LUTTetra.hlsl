// Exact port of Metal/LUTTetra.metal's `lutTetra(sampler, lut, n, intensity)` — hand-written
// tetrahedral 3D-LUT interpolation (the plan's explicit "reference" implementation; trilinear
// is a later preview fast-path). General-kernel I/O convention — see Vignette.hlsl's header
// comment.
//
// ONE deliberate divergence from the Metal source: `fetch()` there flips the strip's row
// ("CIImage(bitmapData:) puts data row 0 at the top, but CI's y axis is bottom-up -> flip the
// row"). D3D11 textures address row 0 at the top already (matching this port's native-side LUT
// upload — GpuCompositor.cpp builds the strip buffer with the SAME row-major layout
// LUTLoader.swift produces, R-fastest per CubeLutParser.h) — there is no bottom-up convention
// to counteract here, so the flip is correctly OMITTED, not a bug.
Texture2D<float4> SourceTex : register(t0);
Texture2D<float4> LutTex : register(t1); // width n, height n*n; node(r,g,b) at pixel (r, b*n+g)
SamplerState PointClamp : register(s0);
SamplerState PointClampLut : register(s1);

cbuffer Params : register(b0)
{
    float N;
    float Intensity;
    float2 _Pad;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float3 FetchLut(float3 idx)
{
    float row = idx.z * N + idx.y;
    float2 texel = float2(idx.x + 0.5, row + 0.5);
    float2 lutSizeTexels = float2(N, N * N);
    return LutTex.SampleLevel(PointClampLut, texel / lutSizeTexels, 0).rgb;
}

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 s = SourceTex.Sample(PointClamp, input.uv);
    float3 rgb = saturate(s.rgb);
    float3 p = rgb * (N - 1.0);
    float3 b0 = clamp(floor(p), 0.0, N - 2.0);
    float3 f = p - b0;

    float3 c000 = FetchLut(b0);
    float3 c111 = FetchLut(b0 + 1.0);
    float3 o;

    if (f.r >= f.g)
    {
        if (f.g >= f.b)
        {
            o = (1.0 - f.r) * c000 + (f.r - f.g) * FetchLut(b0 + float3(1, 0, 0))
                + (f.g - f.b) * FetchLut(b0 + float3(1, 1, 0)) + f.b * c111;
        }
        else if (f.r >= f.b)
        {
            o = (1.0 - f.r) * c000 + (f.r - f.b) * FetchLut(b0 + float3(1, 0, 0))
                + (f.b - f.g) * FetchLut(b0 + float3(1, 0, 1)) + f.g * c111;
        }
        else
        {
            o = (1.0 - f.b) * c000 + (f.b - f.r) * FetchLut(b0 + float3(0, 0, 1))
                + (f.r - f.g) * FetchLut(b0 + float3(1, 0, 1)) + f.g * c111;
        }
    }
    else
    {
        if (f.b >= f.g)
        {
            o = (1.0 - f.b) * c000 + (f.b - f.g) * FetchLut(b0 + float3(0, 0, 1))
                + (f.g - f.r) * FetchLut(b0 + float3(0, 1, 1)) + f.r * c111;
        }
        else if (f.b >= f.r)
        {
            o = (1.0 - f.g) * c000 + (f.g - f.b) * FetchLut(b0 + float3(0, 1, 0))
                + (f.b - f.r) * FetchLut(b0 + float3(0, 1, 1)) + f.r * c111;
        }
        else
        {
            o = (1.0 - f.g) * c000 + (f.g - f.r) * FetchLut(b0 + float3(0, 1, 0))
                + (f.r - f.b) * FetchLut(b0 + float3(1, 1, 0)) + f.b * c111;
        }
    }

    return float4(lerp(s.rgb, o, Intensity), s.a);
}
