#include <CoreImage/CoreImage.h>
using namespace metal;

[[stitchable]] float4 warpBendWave(coreimage::sampler image, float4 rect, float bend, float waveAmp,
                               float waveLength, float wavePhase, coreimage::destination destination) {
    float2 coord = destination.coord();
    float u = clamp((coord.x - rect.x) / max(rect.z, 1.0), 0.0, 1.0);
    float t = 2.0 * u - 1.0;
    float dy = bend * rect.z * 0.25 * (1.0 - t * t);
    dy += waveAmp * sin(6.28318530718 * (coord.x - rect.x) / max(waveLength, 1.0) + wavePhase);
    float2 src = float2(coord.x, coord.y - dy);
    if (src.y < rect.y || src.y > rect.y + rect.w) { return float4(0.0); }
    return image.sample(image.transform(src));
}
