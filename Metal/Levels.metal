#include <CoreImage/CoreImage.h>
using namespace metal;

// Levels: independent black/white-point remap (per-channel linear stretch).
// blacks: <0 crush / >0 lift the floor.  whites: >0 brighten/clip / <0 recover.
extern "C" float4 levels(coreimage::sample_t s, float blacks, float whites) {
    float bp = -blacks * 0.4;
    float wp = 1.0 - whites * 0.4;
    return float4(saturate((s.rgb - bp) / max(0.05, wp - bp)), s.a);
}
