#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform sampler2D u_texB;
uniform float u_progress;
out vec4 frag;
void main() {
  // B pushes A out to the left.
  vec2 uvA = v_uv + vec2(u_progress, 0.0);
  vec2 uvB = v_uv + vec2(u_progress - 1.0, 0.0);
  if (v_uv.x < u_progress) {
    frag = texture(u_texB, uvB + vec2(1.0, 0.0));
  } else {
    frag = texture(u_tex, vec2(v_uv.x - u_progress, v_uv.y));
  }
}
