#include <CoreImage/CoreImage.h>
using namespace metal;

// Cuts the baked matte (coverage in its red channel) into source's alpha; output must be
// premultiplied ourselves or masked-out regions bleed color through when composited.
extern "C" float4 personMask(coreimage::sample_t source, coreimage::sample_t matte, float invert) {
    float coverage = matte.r;
    float a = invert > 0.5 ? 1.0 - coverage : coverage;
    float outAlpha = source.a * a;
    return float4(source.rgb * outAlpha, outAlpha);
}
