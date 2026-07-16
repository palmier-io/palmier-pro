// Combined Y/R/G/B (256 bins each) + saturation-weighted hue (96 bins) histogram over the
// downsampled scope grid — one dispatch, docs/color-scopes-v1.md §3's "one combined pass, not
// two." Two-level reduction: groupshared local counts accumulated with InterlockedAdd, flushed
// to the packed device buffer with InterlockedAdd once per group (§3's groupshared guidance) —
// the standard histogram pattern that avoids every thread contending on the same global atomic.
//
// GridTex holds gamma-encoded, straight (unpremultiplied) RGB — the compositor's accumulator is
// opaque, so premultiplied-by-1.0 already equals straight (§3, no unpremultiply needed).
//
// Packed output buffer layout (length 4*256+96=1120, §3's "one packed buffer, one readback"):
//   [0,256)     Y counts
//   [256,512)   R counts
//   [512,768)   G counts
//   [768,1024)  B counts
//   [1024,1120) hue, fixed-point (kHueFixedPointScale=32768) saturation-weighted sum
Texture2D<float4> GridTex : register(t0);
RWStructuredBuffer<uint> HistogramBuffer : register(u0);

cbuffer HistogramParams : register(b0)
{
    uint GridWidth;
    uint GridHeight;
    uint Pad0;
    uint Pad1;
};

static const int kRgbBins = 256;
static const int kHueBins = 96;
static const float kHueFixedPointScale = 32768.0;
static const float kHueEpsilon = 1e-4;
static const uint kThreadsPerGroup = 64; // numthreads(8,8,1)

groupshared uint localY[kRgbBins];
groupshared uint localR[kRgbBins];
groupshared uint localG[kRgbBins];
groupshared uint localB[kRgbBins];
groupshared uint localHue[kHueBins];

[numthreads(8, 8, 1)]
void HistogramCS(uint3 id : SV_DispatchThreadID, uint groupIndex : SV_GroupIndex)
{
    for (uint i = groupIndex; i < (uint)kRgbBins; i += kThreadsPerGroup)
    {
        localY[i] = 0;
        localR[i] = 0;
        localG[i] = 0;
        localB[i] = 0;
    }
    for (uint h = groupIndex; h < (uint)kHueBins; h += kThreadsPerGroup)
    {
        localHue[h] = 0;
    }
    GroupMemoryBarrierWithGroupSync();

    if (id.x < GridWidth && id.y < GridHeight)
    {
        float3 c = GridTex[int2(id.x, id.y)].rgb;

        // Rec.709 luma (doc §2.1) — deliberately NOT Common.hlsl's Lum() (a different,
        // PDF-blend-mode 0.3/0.59/0.11 constant used for blend modes, not scopes).
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));

        int yBin = clamp((int)floor(luma * (float)kRgbBins), 0, kRgbBins - 1);
        int rBin = clamp((int)floor(c.r * (float)kRgbBins), 0, kRgbBins - 1);
        int gBin = clamp((int)floor(c.g * (float)kRgbBins), 0, kRgbBins - 1);
        int bBin = clamp((int)floor(c.b * (float)kRgbBins), 0, kRgbBins - 1);
        InterlockedAdd(localY[yBin], 1);
        InterlockedAdd(localR[rBin], 1);
        InterlockedAdd(localG[gBin], 1);
        InterlockedAdd(localB[bBin], 1);

        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float d = mx - mn;
        if (d > kHueEpsilon && mx > kHueEpsilon)
        {
            float hue = (c.r == mx) ? (c.g - c.b) / d
                      : (c.g == mx) ? (c.b - c.r) / d + 2.0
                                    : (c.r - c.g) / d + 4.0;
            hue = hue / 6.0;
            hue = hue - floor(hue); // wrap to [0,1) — matches Swift's truncatingRemainder(1) + <0 fixup
            int hueBin = clamp((int)floor(hue * (float)kHueBins), 0, kHueBins - 1);
            uint weight = (uint)round((d / mx) * kHueFixedPointScale);
            InterlockedAdd(localHue[hueBin], weight);
        }
    }

    GroupMemoryBarrierWithGroupSync();

    for (uint j = groupIndex; j < (uint)kRgbBins; j += kThreadsPerGroup)
    {
        if (localY[j] != 0) InterlockedAdd(HistogramBuffer[j], localY[j]);
        if (localR[j] != 0) InterlockedAdd(HistogramBuffer[kRgbBins + j], localR[j]);
        if (localG[j] != 0) InterlockedAdd(HistogramBuffer[2 * kRgbBins + j], localG[j]);
        if (localB[j] != 0) InterlockedAdd(HistogramBuffer[3 * kRgbBins + j], localB[j]);
    }
    for (uint k = groupIndex; k < (uint)kHueBins; k += kThreadsPerGroup)
    {
        if (localHue[k] != 0) InterlockedAdd(HistogramBuffer[4 * kRgbBins + k], localHue[k]);
    }
}
