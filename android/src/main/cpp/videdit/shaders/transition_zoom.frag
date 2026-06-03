#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform sampler2D u_texB;
uniform float u_progress;
out vec4 frag;
void main() {
  // A scales down (zooms out), B scales up from center.
  vec2 c = vec2(0.5);
  float sA = 1.0 + u_progress;          // A grows beyond [0,1]
  float sB = 2.0 - u_progress;          // B shrinks toward 1.0
  vec2 uvA = (v_uv - c) / sA + c;
  vec2 uvB = (v_uv - c) / sB + c;
  vec4 a = texture(u_tex, uvA);
  vec4 b = texture(u_texB, uvB);
  frag = mix(a, b, u_progress);
}
