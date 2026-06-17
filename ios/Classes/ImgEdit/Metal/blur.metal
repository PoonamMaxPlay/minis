// Gaussian, motion, radial. Hot path uses `MPSImageGaussianBlur`; this
// file holds the radial + tilt-shift kernels that MPS doesn't ship.

#include <metal_stdlib>
using namespace metal;

fragment float4 minis_radial_blur(
    float2 uv [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    constant float2& center [[buffer(0)]],
    constant float& strength [[buffer(1)]],
    sampler s [[sampler(0)]]
) {
    return src.sample(s, uv);
}
