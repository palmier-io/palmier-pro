#include <CoreImage/CoreImage.h>
using namespace metal;

// Chroma key: pixels near `keyHue` (and saturated enough) become transparent, with a soft edge.
// `spill` desaturates the leftover key tint on partially-keyed edges. Unpremultiplied I/O.
extern "C" float4 chromaKey(coreimage::sample_t s, float keyHue, float tolerance,
                            float softness, float spill) {
    float3 rgb = s.rgb;
    float mx = max(rgb.r, max(rgb.g, rgb.b));
    float mn = min(rgb.r, min(rgb.g, rgb.b));
    float dd = mx - mn;
    float sat = mx <= 1e-5 ? 0.0 : dd / mx;
    float hue = 0.0;
    if (dd > 1e-5) {
        if (mx == rgb.r) hue = (rgb.g - rgb.b) / dd;
        else if (mx == rgb.g) hue = (rgb.b - rgb.r) / dd + 2.0;
        else hue = (rgb.r - rgb.g) / dd + 4.0;
        hue = fract(hue / 6.0);
    }
    float hd = abs(hue - keyHue);
    hd = min(hd, 1.0 - hd);                                  // circular hue distance, 0…0.5
    float inner = tolerance * 0.25;                          // tolerance 1 ≈ ±90° band
    float key = (1.0 - smoothstep(inner, inner + softness * 0.3 + 0.02, hd))
              * smoothstep(0.12, 0.32, sat)                  // near key hue AND saturated
              * smoothstep(0.04, 0.12, dd);
    float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(rgb, float3(y), spill * key);                  // kill spill on the edges
    return float4(rgb, s.a * (1.0 - key));
}
