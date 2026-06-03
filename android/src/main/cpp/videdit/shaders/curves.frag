#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform sampler2D u_lut_r;   // 256x1 curve LUT for R
uniform sampler2D u_lut_g;
uniform sampler2D u_lut_b;
uniform float u_intensity;
out vec4 frag;
void main() {
  vec4 c = texture(u_tex, v_uv);
  vec3 graded = vec3(
    texture(u_lut_r, vec2(c.r, 0.5)).r,
    texture(u_lut_g, vec2(c.g, 0.5)).r,
    texture(u_lut_b, vec2(c.b, 0.5)).r
  );
  frag = vec4(mix(c.rgb, graded, u_intensity), c.a);
}
