// Separable Gaussian blur, two-pass compute — shared infrastructure for Glow (bloom/halation)
// and Clarity (local-contrast unsharp), matching the plan's "Glow/Clarity: implement the
// separable blur infrastructure (two-pass compute) they share." Core Image's CIGaussianBlur
// does not publish an exact radius<->sigma relationship; this uses sigma = radius/3 (a common
// approximation) with a [-3*sigma, 3*sigma] tap window, capped at kMaxTapRadius texels —
// flagged as an approximate, not bit-exact, port of CIGaussianBlur (see the milestone report).
Texture2D<float4> SourceTex : register(t0);
RWTexture2D<float4> OutputTex : register(u0);

cbuffer BlurParams : register(b0)
{
    float Sigma;
    int TapRadius;
    int Width;
    int Height;
};

static const int kMaxTapRadius = 64;

float GaussianWeight(int offset, float sigma)
{
    float x = (float)offset;
    float s = max(sigma, 1e-4);
    return exp(-(x * x) / (2.0 * s * s));
}

[numthreads(8, 8, 1)]
void BlurHorizontalCS(uint3 id : SV_DispatchThreadID)
{
    if ((int)id.x >= Width || (int)id.y >= Height)
    {
        return;
    }
    int r = min(TapRadius, kMaxTapRadius);
    float4 sum = float4(0, 0, 0, 0);
    float wsum = 0.0;
    for (int i = -r; i <= r; ++i)
    {
        int x = clamp((int)id.x + i, 0, Width - 1);
        float w = GaussianWeight(i, Sigma);
        sum += SourceTex[int2(x, (int)id.y)] * w;
        wsum += w;
    }
    OutputTex[id.xy] = sum / max(wsum, 1e-6);
}

[numthreads(8, 8, 1)]
void BlurVerticalCS(uint3 id : SV_DispatchThreadID)
{
    if ((int)id.x >= Width || (int)id.y >= Height)
    {
        return;
    }
    int r = min(TapRadius, kMaxTapRadius);
    float4 sum = float4(0, 0, 0, 0);
    float wsum = 0.0;
    for (int i = -r; i <= r; ++i)
    {
        int y = clamp((int)id.y + i, 0, Height - 1);
        float w = GaussianWeight(i, Sigma);
        sum += SourceTex[int2((int)id.x, y)] * w;
        wsum += w;
    }
    OutputTex[id.xy] = sum / max(wsum, 1e-6);
}
