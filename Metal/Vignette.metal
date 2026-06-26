#include <CoreImage/CoreImage.h>
using namespace metal;

// Centered, shaped, feathered vignette. `roundness` morphs a superellipse from rectangular
// (frame-following) to round; `midpoint` sets where it starts, `feather` the falloff width.
// amount<0 darkens edges / >0 lightens. Multiplicative → hue-preserving.
extern "C" float4 vignette(coreimage::sampler img, float4 rect, float amount,
                           float midpoint, float roundness, float feather,
                           coreimage::destination dest) {
    float4 s = img.sample(img.coord());
    float2 center = rect.xy + rect.zw * 0.5;
    float2 d = (dest.coord() - center) / max(rect.zw * 0.5, float2(1.0));  // −1…1 across frame
    float p = mix(6.0, 2.0, (roundness + 1.0) * 0.5);                      // −1 rect … +1 round
    float dist = pow(pow(abs(d.x), p) + pow(abs(d.y), p), 1.0 / p);
    float v = smoothstep(midpoint, midpoint + feather * 1.5 + 0.05, dist);
    return float4(saturate(s.rgb * (1.0 + amount * v)), s.a);
}
