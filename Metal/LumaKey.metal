#include <CoreImage/CoreImage.h>
using namespace metal;

// Luma key for white backgrounds: bright pixels become transparent, with a soft edge.
// RGB is attenuated with alpha so keyed white pixels do not leave a fringe.
extern "C" float4 lumaKey(coreimage::sample_t s, float threshold, float softness) {
    threshold = clamp(threshold, 0.0, 1.0);
    softness = clamp(softness, 0.0, 1.0);
    if (threshold >= 0.9999) {
        return float4(s.rgb, s.a);
    }

    float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float key = 0.0;
    if (softness <= 0.0001) {
        key = y >= threshold ? 1.0 : 0.0;
    } else {
        float lower = max(0.0, threshold - softness);
        key = smoothstep(lower, threshold, y);
    }
    float keep = 1.0 - key;
    return float4(s.rgb * keep, s.a * keep);
}
