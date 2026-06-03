// 3D LUT sampler shared with `cpp/imgedit/render_graph.cpp` (GLSL).

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct LutParams {
    float intensity;
    float size;
};

fragment float4 minis_lut3d(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture3d<float, access::sample> lut [[texture(1)]],
    constant LutParams& p [[buffer(0)]],
    sampler s [[sampler(0)]]
) {
    float4 c = src.sample(s, in.uv);
    float scale = (p.size - 1.0) / p.size;
    float offset = 1.0 / (2.0 * p.size);
    float3 graded = lut.sample(s, c.rgb * scale + offset).rgb;
    return float4(mix(c.rgb, graded, p.intensity), c.a);
}
