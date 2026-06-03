#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform sampler2D u_texB;
uniform float u_progress;
uniform vec3 u_dip_color;    // defaults to (0,0,0) when host doesn't set
out vec4 frag;
void main() {
  vec4 a = texture(u_tex, v_uv);
  vec4 b = texture(u_texB, v_uv);
  if (u_progress < 0.5) {
    frag = vec4(mix(a.rgb, u_dip_color, u_progress * 2.0), 1.0);
  } else {
    frag = vec4(mix(u_dip_color, b.rgb, (u_progress - 0.5) * 2.0), 1.0);
  }
}
