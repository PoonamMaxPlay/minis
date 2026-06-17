// Crop / rotate / perspective transform. Applies a 3x3 homography to
// the UV coordinate; out-of-range samples render black.

#include <metal_stdlib>
using namespace metal;

struct CropOut {
    float4 position [[position]];
    float2 uv;
};

struct CropParams {
    float3x3 h;
    int active;
};

vertex CropOut minis_crop_vs(uint vid [[vertex_id]],
                             constant CropParams& p [[buffer(0)]]) {
    float2 pos[4] = { float2(-1, -1), float2( 1, -1),
                      float2(-1,  1), float2( 1,  1) };
    float2 uv[4]  = { float2( 0,  1), float2( 1,  1),
                      float2( 0,  0), float2( 1,  0) };
    CropOut o;
    o.position = float4(pos[vid], 0.0, 1.0);
    float3 t = p.h * float3(uv[vid] - 0.5, 1.0);
    o.uv = (t.xy / t.z) + 0.5;
    return o;
}

fragment float4 minis_crop(
    CropOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    if (any(in.uv < float2(0.0)) || any(in.uv > float2(1.0))) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    return src.sample(s, in.uv);
}
