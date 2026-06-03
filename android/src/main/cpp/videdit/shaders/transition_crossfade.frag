#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;     // A
uniform sampler2D u_texB;    // B
uniform float u_progress;    // [0, 1]
out vec4 frag;
void main() {
  vec4 a = texture(u_tex, v_uv);
  vec4 b = texture(u_texB, v_uv);
  frag = mix(a, b, u_progress);
}
