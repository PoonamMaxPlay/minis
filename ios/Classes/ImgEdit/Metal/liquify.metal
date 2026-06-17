// Forward / inverse warp grid sampler for liquify + face reshape.
// The warp grid is a `texture2d<float>` of (du, dv) displacements
// uploaded by the renderer; brush ops mutate the grid CPU-side.

#include <metal_stdlib>
using namespace metal;

fragment float4 minis_liquify_warp(
    float2 uv [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::sample> warp [[texture(1)]],
    sampler s [[sampler(0)]]
) {
    float2 d = warp.sample(s, uv).xy;
    return src.sample(s, uv + d);
}
