// Per-clip transform+crop+blend into the canvas-sized accumulator. Full-canvas triangle (no
// per-clip scissor/viewport — simpler, correctness-first; a pixel outside the clip's
// transformed+cropped footprint just passes the backdrop through unchanged). Ping-ponged: this
// pass's SourceTex/BackdropTex are the PREVIOUS accumulator; GpuCompositor.cpp swaps render
// targets after each clip so the next clip reads what THIS pass wrote.
//
// `SourceTex` is the clip's fully effect-chain-processed, premultiplied, gamma-encoded,
// NATURAL-RESOLUTION working texture. `InvTransform`/`CropRect` are computed CPU-side
// (GpuCompositor.cpp's BuildClipAffine/ResolveCropRect — identical math to Compositor.cpp's
// CPU path) and passed in as an already-inverted destination-pixel -> source-pixel matrix, so
// this shader only has to do the per-pixel sample + blend math, not the matrix construction.
//
// NORMAL blend mode (mode 0) is a bit-exact HLSL port of Compositor.cpp's
// SourceOverAccumulate/BuildClipAffine/SampleBilinearStraight: premultiply the source's OWN
// straight alpha, fade ONLY the alpha channel by clip opacity (leaving premultiplied RGB at
// full strength — see Compositor.h's "OPACITY FADE" comment for why this is deliberately NOT
// the "scale both RGB and alpha" premultiplied fade). The one acknowledged divergence: the CPU
// path bilinear-samples STRAIGHT 8-bit source then premultiplies; this shader bilinear-samples
// the ALREADY-premultiplied natural-resolution texture then unpremultiplies to reconstruct a
// straight sample. The two only differ at partial-alpha bilinear edges (interior/opaque pixels
// are bit-identical) — see the milestone report.
//
// Non-normal modes: PDF (ISO 32000-1) composite of the source's own straight alpha over the
// backdrop via the per-mode blend function B(Cb,Cs) (Common.hlsl), then a dissolve toward the
// backdrop by the clip's opacity — mirrors FrameRenderer.blend (CIBlendMode filter composited
// over background, then CIDissolveTransition by opacity) exactly.
#include "Common.hlsl"

Texture2D<float4> SourceTex : register(t0);   // clip's natural-res working texture
Texture2D<float4> BackdropTex : register(t1); // canvas-res accumulator (previous state)
SamplerState LinearClamp : register(s0);

cbuffer ClipCompositeParams : register(b0)
{
    float4 InvRow0;  // a, b, c, d  (destPixel -> sourcePixel: sx = a*dx + c*dy + tx)
    float4 InvRow1;  // tx, ty, natWidth, natHeight
    float4 CropRect; // x0, y0, x1, y1 (source pixel space)
    float4 Params;   // opacity, blendModeIndex, canvasWidth, canvasHeight
};

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

float4 PSMain(VSOut input) : SV_TARGET
{
    float2 canvasSize = Params.zw;
    float2 destPixel = input.uv * canvasSize;

    float a = InvRow0.x, b = InvRow0.y, c = InvRow0.z, d = InvRow0.w;
    float tx = InvRow1.x, ty = InvRow1.y;
    float natW = InvRow1.z, natH = InvRow1.w;

    float sx = a * destPixel.x + c * destPixel.y + tx;
    float sy = b * destPixel.x + d * destPixel.y + ty;

    float4 backdrop = BackdropTex.Sample(LinearClamp, input.uv);

    bool outsideCrop = sx < CropRect.x || sx >= CropRect.z || sy < CropRect.y || sy >= CropRect.w;
    bool outsideImage = sx < 0.0 || sy < 0.0 || sx >= natW || sy >= natH;
    if (outsideCrop || outsideImage)
    {
        return backdrop;
    }

    float2 srcUv = float2(sx / natW, sy / natH);
    float4 srcPremult = SourceTex.Sample(LinearClamp, srcUv);
    if (srcPremult.a <= 0.0)
    {
        return backdrop;
    }
    float3 srcStraightRgb = UnpremultiplyRgb(srcPremult);

    float clipOpacity = saturate(Params.x);
    int blendMode = (int)round(Params.y);

    if (blendMode == 0)
    {
        // Bit-exact port of Compositor.cpp's SourceOverAccumulate.
        float outA = srcPremult.a * clipOpacity;
        float3 outRgbPremult = srcStraightRgb * srcPremult.a;
        float invA = 1.0 - outA;
        return float4(outRgbPremult + backdrop.rgb * invA, outA + backdrop.a * invA);
    }

    float3 cb = backdrop.a > kAlphaEpsilon ? backdrop.rgb / backdrop.a : backdrop.rgb;
    float3 cs = srcStraightRgb;
    float3 blendResult = ApplyBlend(blendMode, cb, cs);

    float ab = backdrop.a;
    float as_ = srcPremult.a;
    float3 blendedStraight = as_ * (1.0 - ab) * cs + as_ * ab * blendResult + (1.0 - as_) * ab * cb;
    float blendedAlpha = as_ + ab * (1.0 - as_);

    float3 finalStraight = lerp(cb, blendedStraight, clipOpacity);
    float finalAlpha = lerp(ab, blendedAlpha, clipOpacity);
    return float4(finalStraight * finalAlpha, finalAlpha);
}
