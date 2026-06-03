// Vertex shader for the fullscreen triangle-strip quad and the trivial
// passthrough fragment used to copy a texture into the bound color
// attachment.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut minis_quad_vs(uint vid [[vertex_id]]) {
    // Triangle strip covering NDC quad.
    float2 pos[4] = { float2(-1, -1), float2( 1, -1),
                      float2(-1,  1), float2( 1,  1) };
    float2 uv[4]  = { float2( 0,  1), float2( 1,  1),
                      float2( 0,  0), float2( 1,  0) };
    VertexOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    o.uv = uv[vid];
    return o;
}

fragment float4 minis_passthrough(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    return src.sample(s, in.uv);
}
