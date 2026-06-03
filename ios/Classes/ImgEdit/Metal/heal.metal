// Spot heal composite — final blending pass for the patch-match output.
// PatchMatch itself runs on the CPU side (`heal.swift`, mirrored from
// Android `heal.h`) and writes its result into an offscreen texture
// sampled here.

#include <metal_stdlib>
using namespace metal;

fragment float4 minis_heal_composite(
    float2 uv [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::sample> healed [[texture(1)]],
    texture2d<float, access::sample> mask [[texture(2)]],
    sampler s [[sampler(0)]]
) {
    float4 a = src.sample(s, uv);
    float4 b = healed.sample(s, uv);
    float m = mask.sample(s, uv).r;
    return mix(a, b, m);
}
