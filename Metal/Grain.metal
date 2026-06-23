#include <CoreImage/CoreImage.h>
using namespace metal;

// Film grain: monochromatic, position+frame-seeded noise, strongest in the mid-tones (like film).
// `size` scales the grain; `frame` animates it so it doesn't read as fixed sensor noise.
static float hash13(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

extern "C" float4 grain(coreimage::sampler img, float amount, float size, float frame,
                        coreimage::destination dest) {
    float4 s = img.sample(img.coord());
    float2 co = dest.coord() / max(size, 0.5);
    float n = hash13(float3(co, frame)) - 0.5;
    float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float lumaMask = 4.0 * y * (1.0 - y);   // peaks at mid-gray, fades to black/white
    return float4(saturate(s.rgb + n * amount * 0.35 * lumaMask), s.a);
}
