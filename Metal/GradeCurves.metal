#include <CoreImage/CoreImage.h>
using namespace metal;

// Per-pixel RGB + master(luma) tone curves. Two 256-wide 1D LUTs sampled per pixel:
// lutCh holds the per-channel curves (R=red, G=green, B=blue); lutMaster holds the luma curve.

extern "C" float4 gradeCurves(coreimage::sampler img,
                              coreimage::sampler lutCh,
                              coreimage::sampler lutMaster) {
    float4 s = img.sample(img.coord());
    float3 rgb = saturate(s.rgb);
    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float yp = lutMaster.sample(lutMaster.transform(float2(y * 256.0, 0.5))).r;
    // Luma-preserving rescale, but cap the gain so a shadow-lift curve can't multiply dark
    // saturated pixels (and their compression noise) by a huge factor.
    rgb = (y > 1e-4) ? rgb * min(yp / y, 8.0) : float3(yp);
    float r = lutCh.sample(lutCh.transform(float2(rgb.r * 256.0, 0.5))).r;
    float g = lutCh.sample(lutCh.transform(float2(rgb.g * 256.0, 0.5))).g;
    float b = lutCh.sample(lutCh.transform(float2(rgb.b * 256.0, 0.5))).b;
    return float4(r, g, b, s.a);
}
