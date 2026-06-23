#include <CoreImage/CoreImage.h>
using namespace metal;

// Glow / halation, multi-pass. glowBright isolates highlights above `threshold` and tints them
// warm as `warmth` rises (neutral = bloom, warm = film halation); the host blurs that, then
// glowComposite screen-blends it back over the source.
extern "C" float4 glowBright(coreimage::sample_t s, float threshold, float warmth) {
    float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 hi = s.rgb * smoothstep(threshold, 1.0, y);
    float3 warm = hi * float3(1.0, 0.7, 0.45);          // halation's red-orange cast
    return float4(mix(hi, warm, warmth), s.a);
}

extern "C" float4 glowComposite(coreimage::sampler img, coreimage::sampler glow, float intensity) {
    float4 s = img.sample(img.coord());
    float3 g = saturate(glow.sample(glow.coord()).rgb * intensity);
    return float4(1.0 - (1.0 - s.rgb) * (1.0 - g), s.a);  // screen blend
}
