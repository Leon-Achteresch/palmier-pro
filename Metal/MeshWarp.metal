#include <CoreImage/CoreImage.h>
using namespace metal;

static float3 mwBasis(float t) {
    return float3(2.0 * t * t - 3.0 * t + 1.0, 4.0 * t - 4.0 * t * t, 2.0 * t * t - t);
}

static float3 mwBasisD(float t) {
    return float3(4.0 * t - 3.0, 4.0 - 8.0 * t, 4.0 * t - 1.0);
}

static float2 mwEval(thread const float2 *P, float3 wu, float3 wv) {
    float2 s = float2(0.0);
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
            s += wv[r] * wu[c] * P[r * 3 + c];
        }
    }
    return s;
}

// Inverse of the biquadratic surface: seed from a coarse grid, refine with Newton.
// Folded (self-overlapping) grids resolve to the nearest sheet.
[[stitchable]] float4 meshWarp(coreimage::sampler image, float4 srcRect,
                               float2 p0, float2 p1, float2 p2,
                               float2 p3, float2 p4, float2 p5,
                               float2 p6, float2 p7, float2 p8,
                               coreimage::destination destination) {
    float2 P[9] = {p0, p1, p2, p3, p4, p5, p6, p7, p8};
    float2 target = destination.coord();

    float2 uv = float2(0.5);
    float best = 1e30;
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            float2 g = float2(c / 3.0, r / 3.0);
            float d = length_squared(mwEval(P, mwBasis(g.x), mwBasis(g.y)) - target);
            if (d < best) { best = d; uv = g; }
        }
    }

    for (int i = 0; i < 12; i++) {
        float3 bu = mwBasis(uv.x), bv = mwBasis(uv.y);
        float2 res = mwEval(P, bu, bv) - target;
        float2 su = mwEval(P, mwBasisD(uv.x), bv);
        float2 sv = mwEval(P, bu, mwBasisD(uv.y));
        float det = su.x * sv.y - sv.x * su.y;
        if (fabs(det) < 1e-8) { break; }
        float2 step = float2(sv.y * res.x - sv.x * res.y, -su.y * res.x + su.x * res.y) / det;
        uv -= step;
        uv = clamp(uv, -0.25, 1.25);
        if (length_squared(step) < 1e-12) { break; }
    }

    float2 res = mwEval(P, mwBasis(uv.x), mwBasis(uv.y)) - target;
    if (length_squared(res) > 0.5625 || any(uv < -0.001) || any(uv > 1.001)) {
        return float4(0.0);
    }
    float2 cuv = clamp(uv, 0.0, 1.0);
    float2 src = float2(srcRect.x + cuv.x * srcRect.z, srcRect.y + (1.0 - cuv.y) * srcRect.w);
    return image.sample(image.transform(src));
}
