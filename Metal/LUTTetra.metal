#include <CoreImage/CoreImage.h>
using namespace metal;

// Tetrahedral 3D-LUT interpolation. The cube is passed as a 2D strip
// (width n, height n²; node (r,g,b) at pixel (r, b·n + g)); corners are fetched nearest
// (exact texel centers) and blended within the tetrahedron containing the sample.

static float3 fetch(coreimage::sampler lut, float n, float3 idx) {
    // CIImage(bitmapData:) puts data row 0 at the top, but CI's y axis is bottom-up → flip the row.
    float row = idx.z * n + idx.y;
    return lut.sample(lut.transform(float2(idx.x + 0.5, n * n - 1.0 - row + 0.5))).rgb;
}

extern "C" float4 lutTetra(coreimage::sampler img, coreimage::sampler lut, float n, float intensity) {
    float4 s = img.sample(img.coord());
    float3 rgb = saturate(s.rgb);
    float3 p = rgb * (n - 1.0);
    float3 b0 = clamp(floor(p), 0.0, n - 2.0);
    float3 f = p - b0;

    float3 c000 = fetch(lut, n, b0);
    float3 c111 = fetch(lut, n, b0 + 1.0);
    float3 o;
    if (f.r >= f.g) {
        if (f.g >= f.b) {
            o = (1.0 - f.r) * c000 + (f.r - f.g) * fetch(lut, n, b0 + float3(1, 0, 0))
                + (f.g - f.b) * fetch(lut, n, b0 + float3(1, 1, 0)) + f.b * c111;
        } else if (f.r >= f.b) {
            o = (1.0 - f.r) * c000 + (f.r - f.b) * fetch(lut, n, b0 + float3(1, 0, 0))
                + (f.b - f.g) * fetch(lut, n, b0 + float3(1, 0, 1)) + f.g * c111;
        } else {
            o = (1.0 - f.b) * c000 + (f.b - f.r) * fetch(lut, n, b0 + float3(0, 0, 1))
                + (f.r - f.g) * fetch(lut, n, b0 + float3(1, 0, 1)) + f.g * c111;
        }
    } else {
        if (f.b >= f.g) {
            o = (1.0 - f.b) * c000 + (f.b - f.g) * fetch(lut, n, b0 + float3(0, 0, 1))
                + (f.g - f.r) * fetch(lut, n, b0 + float3(0, 1, 1)) + f.r * c111;
        } else if (f.b >= f.r) {
            o = (1.0 - f.g) * c000 + (f.g - f.b) * fetch(lut, n, b0 + float3(0, 1, 0))
                + (f.b - f.r) * fetch(lut, n, b0 + float3(0, 1, 1)) + f.r * c111;
        } else {
            o = (1.0 - f.g) * c000 + (f.g - f.r) * fetch(lut, n, b0 + float3(0, 1, 0))
                + (f.r - f.b) * fetch(lut, n, b0 + float3(1, 1, 0)) + f.b * c111;
        }
    }
    return float4(mix(s.rgb, o, intensity), s.a);
}
