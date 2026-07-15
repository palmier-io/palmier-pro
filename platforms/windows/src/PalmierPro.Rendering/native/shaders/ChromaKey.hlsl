// Exact port of Metal/ChromaKey.metal's `chromaKey(sample_t, keyHue, tolerance, softness,
// spill)`. ColorKernel I/O convention (unpremultiplied) — the Metal source's own header
// comment already says "Unpremultiplied I/O", confirming this is the CIColorKernel path (see
// Levels.hlsl's header comment for what that means for this port). Unlike the other
// ColorKernel-style effects, this one ALSO modifies alpha (the key itself), so the
// re-premultiply step uses the NEW alpha, not the source's.
#include "Common.hlsl"

Texture2D<float4> SourceTex : register(t0);
SamplerState LinearClamp : register(s0);

cbuffer Params : register(b0)
{
    float KeyHue;
    float Tolerance;
    float Softness;
    float Spill;
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float4 premult = SourceTex.Sample(LinearClamp, input.uv);
    float3 rgb = UnpremultiplyRgb(premult);
    float srcAlpha = premult.a;

    float mx = max(rgb.r, max(rgb.g, rgb.b));
    float mn = min(rgb.r, min(rgb.g, rgb.b));
    float dd = mx - mn;
    float sat = mx <= 1e-5 ? 0.0 : dd / mx;

    float hue = 0.0;
    if (dd > 1e-5)
    {
        if (mx == rgb.r) hue = (rgb.g - rgb.b) / dd;
        else if (mx == rgb.g) hue = (rgb.b - rgb.r) / dd + 2.0;
        else hue = (rgb.r - rgb.g) / dd + 4.0;
        hue = frac(hue / 6.0);
    }

    float hd = abs(hue - KeyHue);
    hd = min(hd, 1.0 - hd);
    float inner = Tolerance * 0.25;
    float key = (1.0 - smoothstep(inner, inner + Softness * 0.3 + 0.02, hd))
        * smoothstep(0.12, 0.32, sat)
        * smoothstep(0.04, 0.12, dd);

    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = lerp(rgb, float3(y, y, y), Spill * key);

    float outAlpha = srcAlpha * (1.0 - key);
    return Premultiply(rgb, outAlpha);
}
