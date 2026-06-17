// Metal mirrors of the GL ES transition shaders in
// android/src/main/cpp/videdit/shaders/. Naming matches the dictionary in
// MetalCompositor.swift (vs_quad + ps_<name>).
#include <metal_stdlib>
using namespace metal;

struct VertexIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
struct VertexOut { float4 pos [[position]]; float2 uv; };

struct Uniforms {
  float progress;
  float lutAmount;
  float pad0;
  float pad1;
};

vertex VertexOut vs_quad(uint vid [[vertex_id]]) {
  const float2 kPos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
  const float2 kUV [4] = { float2(0,1),   float2(1,1),  float2(0,0),  float2(1,0) };
  VertexOut o;
  o.pos = float4(kPos[vid], 0, 1);
  o.uv  = kUV[vid];
  return o;
}

fragment float4 ps_passthrough(VertexOut in [[stage_in]],
                               texture2d<float> texA [[texture(0)]]) {
  constexpr sampler smp(mag_filter::linear, min_filter::linear);
  return texA.sample(smp, in.uv);
}

fragment float4 ps_crossfade(VertexOut in [[stage_in]],
                             texture2d<float> texA [[texture(0)]],
                             texture2d<float> texB [[texture(1)]],
                             constant Uniforms& u [[buffer(0)]]) {
  constexpr sampler smp(mag_filter::linear, min_filter::linear);
  return mix(texA.sample(smp, in.uv), texB.sample(smp, in.uv), u.progress);
}

fragment float4 ps_dip(VertexOut in [[stage_in]],
                       texture2d<float> texA [[texture(0)]],
                       texture2d<float> texB [[texture(1)]],
                       constant Uniforms& u [[buffer(0)]]) {
  constexpr sampler smp(mag_filter::linear, min_filter::linear);
  float3 dipColor = float3(0.0);
  float3 a = texA.sample(smp, in.uv).rgb;
  float3 b = texB.sample(smp, in.uv).rgb;
  float3 c = u.progress < 0.5
      ? mix(a, dipColor, u.progress * 2.0)
      : mix(dipColor, b, (u.progress - 0.5) * 2.0);
  return float4(c, 1.0);
}

fragment float4 ps_slide(VertexOut in [[stage_in]],
                         texture2d<float> texA [[texture(0)]],
                         texture2d<float> texB [[texture(1)]],
                         constant Uniforms& u [[buffer(0)]]) {
  constexpr sampler smp(mag_filter::linear, min_filter::linear);
  float2 uvA = in.uv + float2(u.progress, 0);
  float2 uvB = in.uv - float2(1.0 - u.progress, 0);
  if (uvA.x >= 0.0 && uvA.x <= 1.0) return texA.sample(smp, uvA);
  if (uvB.x >= 0.0 && uvB.x <= 1.0) return texB.sample(smp, uvB);
  return float4(0, 0, 0, 1);
}

fragment float4 ps_push(VertexOut in [[stage_in]],
                        texture2d<float> texA [[texture(0)]],
                        texture2d<float> texB [[texture(1)]],
                        constant Uniforms& u [[buffer(0)]]) {
  constexpr sampler smp(mag_filter::linear, min_filter::linear);
  if (in.uv.x < u.progress) {
    return texB.sample(smp, in.uv + float2(1.0 - u.progress, 0));
  } else {
    return texA.sample(smp, float2(in.uv.x - u.progress, in.uv.y));
  }
}

fragment float4 ps_zoom(VertexOut in [[stage_in]],
                        texture2d<float> texA [[texture(0)]],
                        texture2d<float> texB [[texture(1)]],
                        constant Uniforms& u [[buffer(0)]]) {
  constexpr sampler smp(mag_filter::linear, min_filter::linear);
  float2 c = float2(0.5);
  float sA = 1.0 + u.progress;
  float sB = 2.0 - u.progress;
  float2 uvA = (in.uv - c) / sA + c;
  float2 uvB = (in.uv - c) / sB + c;
  return mix(texA.sample(smp, uvA), texB.sample(smp, uvB), u.progress);
}

static inline float rand_f(float2 p) {
  return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

fragment float4 ps_glitch(VertexOut in [[stage_in]],
                          texture2d<float> texA [[texture(0)]],
                          texture2d<float> texB [[texture(1)]],
                          constant Uniforms& u [[buffer(0)]]) {
  constexpr sampler smp(mag_filter::linear, min_filter::linear);
  float t = u.progress;
  float band = step(0.5, fract(in.uv.y * 24.0 + t * 8.0));
  float offset = (rand_f(float2(floor(in.uv.y * 24.0), t)) - 0.5)
                 * 0.04 * (1.0 - abs(t - 0.5) * 2.0);
  float2 uvR = in.uv + float2(offset, 0);
  float2 uvB = in.uv - float2(offset, 0);
  float3 a = float3(texA.sample(smp, uvR).r,
                    texA.sample(smp, in.uv).g,
                    texA.sample(smp, uvB).b);
  float3 b = float3(texB.sample(smp, uvR).r,
                    texB.sample(smp, in.uv).g,
                    texB.sample(smp, uvB).b);
  float3 c = mix(a, b, t);
  if (band > 0.5 && t > 0.1 && t < 0.9) {
    c = mix(c, float3(rand_f(in.uv + t)), 0.15);
  }
  return float4(c, 1.0);
}

fragment float4 ps_curves(VertexOut in [[stage_in]],
                          texture2d<float> texA [[texture(0)]],
                          texture2d<float> lutR [[texture(1)]],
                          texture2d<float> lutG [[texture(2)]],
                          texture2d<float> lutB [[texture(3)]],
                          constant Uniforms& u [[buffer(0)]]) {
  constexpr sampler smp(mag_filter::linear, min_filter::linear);
  float4 c = texA.sample(smp, in.uv);
  float r = lutR.sample(smp, float2(c.r, 0.5)).r;
  float g = lutG.sample(smp, float2(c.g, 0.5)).r;
  float b = lutB.sample(smp, float2(c.b, 0.5)).r;
  return float4(mix(c.rgb, float3(r, g, b), u.lutAmount), c.a);
}
