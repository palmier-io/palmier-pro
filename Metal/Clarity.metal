#include <CoreImage/CoreImage.h>
using namespace metal;

// Clarity = local-contrast unsharp against a mid-radius blur. Dehaze pushes contrast, local
// contrast and saturation, weighted by the dark-channel prior (haze = high min-channel) so it's
// strongest on washed-out regions but still visible everywhere.
extern "C" float4 clarityHaze(coreimage::sampler img, coreimage::sampler blurred,
                              float clarity, float dehaze) {
    float4 s = img.sample(img.coord());
    float3 b = blurred.sample(blurred.coord()).rgb;
    float3 rgb = s.rgb + (s.rgb - b) * clarity;
    if (dehaze != 0.0) {
        float dark = min(s.rgb.r, min(s.rgb.g, s.rgb.b));            // high = hazy
        float w = dehaze * (0.5 + 0.5 * smoothstep(0.05, 0.5, dark));
        rgb += (s.rgb - b) * (w * 0.6);                              // local contrast
        rgb = mix(float3(0.45), rgb, 1.0 + w * 0.45);               // contrast, pivot low to crush the veil
        float yy = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(yy), rgb, 1.0 + w * 0.5);                  // re-saturate
    }
    return float4(saturate(rgb), s.a);
}
