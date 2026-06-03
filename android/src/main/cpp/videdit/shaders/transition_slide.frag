#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform sampler2D u_texB;
uniform float u_progress;
out vec4 frag;
void main() {
  // A slides left, B slides in from the right.
  vec2 uvA = v_uv + vec2(u_progress, 0.0);
  vec2 uvB = v_uv - vec2(1.0 - u_progress, 0.0);
  bool inA = uvA.x >= 0.0 && uvA.x <= 1.0;
  bool inB = uvB.x >= 0.0 && uvB.x <= 1.0;
  if (inA) frag = texture(u_tex, uvA);
  else if (inB) frag = texture(u_texB, uvB);
  else frag = vec4(0.0, 0.0, 0.0, 1.0);
}
