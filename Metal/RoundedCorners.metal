#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" float4 roundedCorners(coreimage::sampler image, float4 rect, float rounding,
                                  coreimage::destination destination) {
    float4 sample = image.sample(image.coord());
    float radius = saturate(rounding) * min(rect.z, rect.w) * 0.5;
    float2 center = rect.xy + rect.zw * 0.5;
    float2 insetHalfSize = rect.zw * 0.5 - radius;
    float2 q = abs(destination.coord() - center) - insetHalfSize;
    float distance = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float coverage = 1.0 - smoothstep(-0.5, 0.5, distance);
    return float4(sample.rgb, sample.a * coverage);
}
