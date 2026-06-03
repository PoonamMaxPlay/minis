#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform sampler2D u_texB;
uniform float u_progress;
out vec4 frag;

float rand(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
  // RGB-split offset modulated by sin(p * tau * 8) + random horizontal slabs.
  float t = u_progress;
  float band = step(0.5, fract(v_uv.y * 24.0 + t * 8.0));
  float offset = (rand(vec2(floor(v_uv.y * 24.0), t)) - 0.5) * 0.04 * (1.0 - abs(t - 0.5) * 2.0);
  vec2 uvR = v_uv + vec2(offset, 0.0);
  vec2 uvG = v_uv;
  vec2 uvB = v_uv - vec2(offset, 0.0);
  vec3 a = vec3(texture(u_tex, uvR).r, texture(u_tex, uvG).g, texture(u_tex, uvB).b);
  vec3 b = vec3(texture(u_texB, uvR).r, texture(u_texB, uvG).g, texture(u_texB, uvB).b);
  vec3 c = mix(a, b, t);
  if (band > 0.5 && t > 0.1 && t < 0.9) {
    c = mix(c, vec3(rand(v_uv + t)), 0.15);
  }
  frag = vec4(c, 1.0);
}
