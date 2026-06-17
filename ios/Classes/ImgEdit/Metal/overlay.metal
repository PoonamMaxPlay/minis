// Layer composite shader. Mirrors GLSL `kFsOverlay` in
// `cpp/imgedit/render_graph.cpp`.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct OverlayParams {
    float opacity;
    int blend;
};

inline float3 blend_multiply(float3 a, float3 b) { return a * b; }
inline float3 blend_screen(float3 a, float3 b) { return 1.0 - (1.0 - a) * (1.0 - b); }
inline float3 blend_overlay(float3 a, float3 b) {
    return mix(2.0 * a * b, 1.0 - 2.0 * (1.0 - a) * (1.0 - b), step(0.5, a));
}

fragment float4 minis_overlay_composite(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::sample> layer [[texture(1)]],
    constant OverlayParams& p [[buffer(0)]],
    sampler s [[sampler(0)]]
) {
    float4 base = src.sample(s, in.uv);
    float4 top  = layer.sample(s, in.uv);
    float3 blended = top.rgb;
    if (p.blend == 1) blended = blend_multiply(base.rgb, top.rgb);
    else if (p.blend == 2) blended = blend_screen(base.rgb, top.rgb);
    else if (p.blend == 3) blended = blend_overlay(base.rgb, top.rgb);
    float a = top.a * p.opacity;
    return float4(mix(base.rgb, blended, a), max(base.a, a));
}
