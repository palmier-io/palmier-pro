// Box-filter downsample of the compositor's canvas-sized accumulator to the <=320x180 scope
// grid (docs/color-scopes-v1.md §3: scale = min(1, min(320/width, 180/height))). One thread per
// output grid texel; averages the corresponding source-space box using integer-aligned
// boundaries (floor(gx*srcW/gridW) .. floor((gx+1)*srcW/gridW)), so every source pixel is
// counted in exactly one grid cell — no gaps, no double-counting.
Texture2D<float4> SourceTex : register(t0);
RWTexture2D<float4> GridTex : register(u0);

cbuffer DownsampleParams : register(b0)
{
    uint SourceWidth;
    uint SourceHeight;
    uint GridWidth;
    uint GridHeight;
};

[numthreads(8, 8, 1)]
void DownsampleCS(uint3 id : SV_DispatchThreadID)
{
    if (id.x >= GridWidth || id.y >= GridHeight)
    {
        return;
    }

    uint x0 = (id.x * SourceWidth) / GridWidth;
    uint x1 = ((id.x + 1) * SourceWidth) / GridWidth;
    uint y0 = (id.y * SourceHeight) / GridHeight;
    uint y1 = ((id.y + 1) * SourceHeight) / GridHeight;
    x1 = max(x1, x0 + 1);
    y1 = max(y1, y0 + 1);

    float4 sum = float4(0, 0, 0, 0);
    uint count = 0;
    for (uint y = y0; y < y1 && y < SourceHeight; ++y)
    {
        for (uint x = x0; x < x1 && x < SourceWidth; ++x)
        {
            sum += SourceTex[int2(x, y)];
            ++count;
        }
    }
    GridTex[id.xy] = count > 0 ? sum / (float)count : float4(0, 0, 0, 1);
}
