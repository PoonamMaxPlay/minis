// B3 adjustment shader: exposure, contrast, saturation, temperature, tint,
// sharpen, clarity, dehaze. Same math as the GLSL version in
// `cpp/imgedit/render_graph.cpp` so output is platform-stable.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct AdjustParams {
    float exposure;
    float contrast;
    float saturation;
    float temperature;
    float tint;
    float sharpen;
    float clarity;
    float dehaze;
    float2 px;
};

inline float3 box_blur(texture2d<float, access::sample> src,
                       sampler s, float2 uv, float2 px, float r) {
    float3 acc = float3(0.0);
    int n = 0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            acc += src.sample(s, uv + float2(float(dx), float(dy)) * px * r).rgb;
            n += 1;
        }
    }
    return acc / float(n);
}

fragment float4 minis_adjust(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> src [[texture(0)]],
    constant AdjustParams& p [[buffer(0)]],
    sampler s [[sampler(0)]]
) {
    float4 col = src.sample(s, in.uv);
    float3 c = col.rgb;
    c *= pow(2.0, p.exposure);
    c = (c - 0.5) * (1.0 + p.contrast) + 0.5;
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(luma), c, p.saturation);
    c.r += p.temperature * 0.15;
    c.b -= p.temperature * 0.15;
    c.g += p.tint * 0.15;
    if (p.sharpen > 0.0) {
        float3 b = box_blur(src, s, in.uv, p.px, 1.0);
        c += p.sharpen * (c - b);
    }
    if (p.clarity > 0.0) {
        float3 b2 = box_blur(src, s, in.uv, p.px, 3.0);
        float lc = dot(c - b2, float3(0.2126, 0.7152, 0.0722));
        c += p.clarity * lc;
    }
    if (p.dehaze > 0.0) {
        float dc = min(min(c.r, c.g), c.b);
        c -= p.dehaze * dc * 0.5;
    }
    return float4(clamp(c, 0.0, 1.0), col.a);
}
