#include <CoreImage/CoreImage.h>
using namespace metal;

// Luma-masked highlights & shadows. Adds a tone-region-weighted luminance delta to RGB

extern "C" float4 highlightsShadows(coreimage::sample_t s, float highlights, float shadows) {
    float3 rgb = s.rgb;
    float y = dot(saturate(rgb), float3(0.2126, 0.7152, 0.0722));
    float hi = y * y * y;                          // peaks at white
    float lo = (1.0 - y) * (1.0 - y) * (1.0 - y);  // peaks at black
    float dY = (highlights * hi + shadows * lo) * 0.5;
    return float4(saturate(rgb + dY), s.a);
}
