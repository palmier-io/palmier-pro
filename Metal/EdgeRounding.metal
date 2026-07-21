#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" float4 edgeRounding(coreimage::sampler image, float4 rect, float edgeRounding, float edgeSoftness,
                               coreimage::destination destination) {
    float4 sample = image.sample(image.coord());
    float radius = saturate(edgeRounding) * min(rect.z, rect.w) * 0.5;
    float feather = saturate(edgeSoftness) * min(rect.z, rect.w) * 0.5;
    float2 center = rect.xy + rect.zw * 0.5;
    float2 insetHalfSize = rect.zw * 0.5 - radius;
    float2 q = abs(destination.coord() - center) - insetHalfSize;
    float distance = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float coverage = 1.0 - smoothstep(-0.5 - feather, 0.5, distance);
    return float4(sample.rgb, sample.a * coverage);
}
