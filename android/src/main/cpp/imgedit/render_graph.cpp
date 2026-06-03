#include "render_graph.h"

#include <android/log.h>
#include <cstring>

#define LOG_TAG "MinisImgEditGraph"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace minis::imgedit {

namespace {

const char* kVsQuad = R"(#version 300 es
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
out vec2 v_uv;
void main() {
  v_uv = a_uv;
  gl_Position = vec4(a_pos, 0.0, 1.0);
}
)";

const char* kVsCrop = R"(#version 300 es
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
uniform mat3 u_h;
out vec2 v_uv;
void main() {
  vec3 p = u_h * vec3(a_uv - 0.5, 1.0);
  v_uv = (p.xy / p.z) + 0.5;
  gl_Position = vec4(a_pos, 0.0, 1.0);
}
)";

const char* kFsPassthrough = R"(#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_src;
out vec4 o_col;
void main() {
  o_col = texture(u_src, v_uv);
}
)";

// Full adjust pipeline implements B3 spec.
const char* kFsAdjust = R"(#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_src;
uniform float u_exposure;
uniform float u_contrast;
uniform float u_saturation;
uniform float u_temperature;
uniform float u_tint;
uniform float u_sharpen;
uniform float u_clarity;
uniform float u_dehaze;
uniform vec2  u_px;
out vec4 o_col;

vec3 sample3(vec2 uv) { return texture(u_src, uv).rgb; }

vec3 boxblur(vec2 uv, float r) {
  vec3 s = vec3(0.0);
  float n = 0.0;
  for (int dy = -1; dy <= 1; ++dy) {
    for (int dx = -1; dx <= 1; ++dx) {
      s += sample3(uv + vec2(float(dx), float(dy)) * u_px * r);
      n += 1.0;
    }
  }
  return s / n;
}

void main() {
  vec4 col = texture(u_src, v_uv);
  vec3 c = col.rgb;
  c *= pow(2.0, u_exposure);
  c = (c - 0.5) * (1.0 + u_contrast) + 0.5;
  float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c = mix(vec3(luma), c, u_saturation);
  c.r += u_temperature * 0.15;
  c.b -= u_temperature * 0.15;
  c.g += u_tint * 0.15;
  if (u_sharpen > 0.0) {
    vec3 b = boxblur(v_uv, 1.0);
    c += u_sharpen * (c - b);
  }
  if (u_clarity > 0.0) {
    vec3 b2 = boxblur(v_uv, 3.0);
    float lc = dot(c - b2, vec3(0.2126, 0.7152, 0.0722));
    c += u_clarity * lc;
  }
  if (u_dehaze > 0.0) {
    float dc = min(min(c.r, c.g), c.b);
    c -= u_dehaze * dc * 0.5;
  }
  o_col = vec4(clamp(c, 0.0, 1.0), col.a);
}
)";

const char* kFsLut = R"(#version 300 es
precision mediump float;
precision mediump sampler3D;
in vec2 v_uv;
uniform sampler2D u_src;
uniform sampler3D u_lut;
uniform float u_intensity;
uniform float u_lut_size;
out vec4 o_col;
void main() {
  vec4 src = texture(u_src, v_uv);
  float scale = (u_lut_size - 1.0) / u_lut_size;
  float offset = 1.0 / (2.0 * u_lut_size);
  vec3 graded = texture(u_lut, src.rgb * scale + offset).rgb;
  o_col = vec4(mix(src.rgb, graded, u_intensity), src.a);
}
)";

const char* kFsCrop = R"(#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_src;
out vec4 o_col;
void main() {
  if (any(lessThan(v_uv, vec2(0.0))) || any(greaterThan(v_uv, vec2(1.0)))) {
    o_col = vec4(0.0, 0.0, 0.0, 1.0);
  } else {
    o_col = texture(u_src, v_uv);
  }
}
)";

const char* kFsOverlay = R"(#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_src;     // current composite
uniform sampler2D u_layer;   // layer to composite over
uniform float u_opacity;
uniform int u_blend;
out vec4 o_col;

vec3 blend_multiply(vec3 a, vec3 b) { return a * b; }
vec3 blend_screen(vec3 a, vec3 b) { return 1.0 - (1.0 - a) * (1.0 - b); }
vec3 blend_overlay(vec3 a, vec3 b) {
  return mix(2.0 * a * b, 1.0 - 2.0 * (1.0 - a) * (1.0 - b),
             step(0.5, a));
}

void main() {
  vec4 base = texture(u_src, v_uv);
  vec4 top  = texture(u_layer, v_uv);
  vec3 blended = top.rgb;
  if (u_blend == 1) blended = blend_multiply(base.rgb, top.rgb);
  else if (u_blend == 2) blended = blend_screen(base.rgb, top.rgb);
  else if (u_blend == 3) blended = blend_overlay(base.rgb, top.rgb);
  float a = top.a * u_opacity;
  o_col = vec4(mix(base.rgb, blended, a), max(base.a, a));
}
)";

void check_err(const char* tag) {
  GLenum e = glGetError();
  if (e != 0) LOGE("GL err 0x%x at %s", e, tag);
}

GLuint compile(GLenum type, const char* src) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, nullptr);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char buf[1024] = {0};
    glGetShaderInfoLog(s, sizeof(buf), nullptr, buf);
    LOGE("shader compile fail: %s", buf);
    glDeleteShader(s);
    return 0;
  }
  return s;
}

}  // namespace

RenderGraph::RenderGraph() = default;
RenderGraph::~RenderGraph() { destroy(); }

GLuint RenderGraph::compile_program(const char* vs, const char* fs) {
  GLuint v = compile(GL_VERTEX_SHADER, vs);
  GLuint f = compile(GL_FRAGMENT_SHADER, fs);
  if (v == 0 || f == 0) return 0;
  GLuint p = glCreateProgram();
  glAttachShader(p, v);
  glAttachShader(p, f);
  glLinkProgram(p);
  glDeleteShader(v);
  glDeleteShader(f);
  GLint ok = 0;
  glGetProgramiv(p, GL_LINK_STATUS, &ok);
  if (!ok) {
    char buf[1024] = {0};
    glGetProgramInfoLog(p, sizeof(buf), nullptr, buf);
    LOGE("program link fail: %s", buf);
    glDeleteProgram(p);
    return 0;
  }
  return p;
}

bool RenderGraph::init_programs() {
  // Fullscreen triangle-strip quad — NDC + uv.
  const float verts[] = {
    -1.f, -1.f, 0.f, 0.f,
     1.f, -1.f, 1.f, 0.f,
    -1.f,  1.f, 0.f, 1.f,
     1.f,  1.f, 1.f, 1.f,
  };
  glGenVertexArrays(1, &vao_);
  glBindVertexArray(vao_);
  glGenBuffers(1, &vbo_);
  glBindBuffer(GL_ARRAY_BUFFER, vbo_);
  glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                        (void*)(2 * sizeof(float)));
  glEnableVertexAttribArray(1);
  glBindVertexArray(0);

  prog_passthrough_ = compile_program(kVsQuad, kFsPassthrough);
  prog_adjust_      = compile_program(kVsQuad, kFsAdjust);
  prog_lut_         = compile_program(kVsQuad, kFsLut);
  prog_crop_        = compile_program(kVsCrop, kFsCrop);
  prog_overlay_     = compile_program(kVsQuad, kFsOverlay);

  return prog_passthrough_ && prog_adjust_ && prog_lut_ && prog_crop_ && prog_overlay_;
}

bool RenderGraph::resize(int32_t w, int32_t h) {
  if (w <= 0 || h <= 0) return false;
  if (w == width_ && h == height_) return true;
  width_ = w;
  height_ = h;

  GLuint* fbos[2] = {&fbo_a_, &fbo_b_};
  GLuint* texs[2] = {&tex_a_, &tex_b_};
  for (int i = 0; i < 2; ++i) {
    if (*fbos[i]) glDeleteFramebuffers(1, fbos[i]);
    if (*texs[i]) glDeleteTextures(1, texs[i]);
    glGenTextures(1, texs[i]);
    glBindTexture(GL_TEXTURE_2D, *texs[i]);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, fbos[i]);
    glBindFramebuffer(GL_FRAMEBUFFER, *fbos[i]);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, *texs[i], 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      LOGE("FBO incomplete");
      return false;
    }
  }
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  output_tex_ = tex_a_;
  return true;
}

void RenderGraph::draw_quad(GLuint program) {
  glUseProgram(program);
  glBindVertexArray(vao_);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glBindVertexArray(0);
}

void RenderGraph::execute(const std::vector<Pass>& passes, bool present) {
  if (width_ == 0 || height_ == 0 || base_tex_ == 0) return;

  glViewport(0, 0, width_, height_);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_BLEND);

  // Seed ping with base into fbo_a.
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_a_);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, base_tex_);

  if (crop_.active) {
    glUseProgram(prog_crop_);
    GLint loc_h = glGetUniformLocation(prog_crop_, "u_h");
    glUniformMatrix3fv(loc_h, 1, GL_FALSE, crop_.homography);
    GLint loc_src = glGetUniformLocation(prog_crop_, "u_src");
    glUniform1i(loc_src, 0);
    draw_quad(prog_crop_);
  } else {
    glUseProgram(prog_passthrough_);
    GLint loc_src = glGetUniformLocation(prog_passthrough_, "u_src");
    glUniform1i(loc_src, 0);
    draw_quad(prog_passthrough_);
  }

  GLuint cur_tex = tex_a_;
  GLuint cur_fbo = fbo_b_;
  GLuint next_tex = tex_b_;

  auto run_pass = [&](GLuint program) {
    glBindFramebuffer(GL_FRAMEBUFFER, cur_fbo);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, cur_tex);
    glUseProgram(program);
    GLint loc_src = glGetUniformLocation(program, "u_src");
    glUniform1i(loc_src, 0);
    draw_quad(program);
    std::swap(cur_tex, next_tex);
    std::swap(cur_fbo, fbo_a_);
    if (cur_fbo == fbo_a_) {
      // we swapped; pick the unused fbo
      cur_fbo = (cur_tex == tex_a_) ? fbo_b_ : fbo_a_;
      next_tex = (cur_tex == tex_a_) ? tex_b_ : tex_a_;
    }
  };

  // Adjust pass
  bool has_adjust = adjust_.exposure != 0 || adjust_.contrast != 0 ||
                    adjust_.saturation != 1 || adjust_.temperature != 0 ||
                    adjust_.tint != 0 || adjust_.sharpen != 0 ||
                    adjust_.clarity != 0 || adjust_.dehaze != 0;
  if (has_adjust) {
    glBindFramebuffer(GL_FRAMEBUFFER, cur_fbo);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, cur_tex);
    glUseProgram(prog_adjust_);
    glUniform1i(glGetUniformLocation(prog_adjust_, "u_src"), 0);
    glUniform1f(glGetUniformLocation(prog_adjust_, "u_exposure"), adjust_.exposure);
    glUniform1f(glGetUniformLocation(prog_adjust_, "u_contrast"), adjust_.contrast);
    glUniform1f(glGetUniformLocation(prog_adjust_, "u_saturation"), adjust_.saturation);
    glUniform1f(glGetUniformLocation(prog_adjust_, "u_temperature"), adjust_.temperature);
    glUniform1f(glGetUniformLocation(prog_adjust_, "u_tint"), adjust_.tint);
    glUniform1f(glGetUniformLocation(prog_adjust_, "u_sharpen"), adjust_.sharpen);
    glUniform1f(glGetUniformLocation(prog_adjust_, "u_clarity"), adjust_.clarity);
    glUniform1f(glGetUniformLocation(prog_adjust_, "u_dehaze"), adjust_.dehaze);
    glUniform2f(glGetUniformLocation(prog_adjust_, "u_px"),
                1.0f / (float)width_, 1.0f / (float)height_);
    draw_quad(prog_adjust_);
    GLuint tmp_tex = cur_tex; cur_tex = next_tex; next_tex = tmp_tex;
    GLuint tmp_fbo = cur_fbo; cur_fbo = (cur_tex == tex_a_) ? fbo_b_ : fbo_a_; (void)tmp_fbo;
  }

  // LUT pass
  if (lut_.texture != 0 && lut_.intensity > 0.0f && lut_.size > 0) {
    glBindFramebuffer(GL_FRAMEBUFFER, cur_fbo);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, cur_tex);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_3D, lut_.texture);
    glUseProgram(prog_lut_);
    glUniform1i(glGetUniformLocation(prog_lut_, "u_src"), 0);
    glUniform1i(glGetUniformLocation(prog_lut_, "u_lut"), 1);
    glUniform1f(glGetUniformLocation(prog_lut_, "u_intensity"), lut_.intensity);
    glUniform1f(glGetUniformLocation(prog_lut_, "u_lut_size"), (float)lut_.size);
    draw_quad(prog_lut_);
    GLuint tmp_tex = cur_tex; cur_tex = next_tex; next_tex = tmp_tex;
    cur_fbo = (cur_tex == tex_a_) ? fbo_b_ : fbo_a_;
  }

  // Per-layer composite passes (draw/sticker/text/mask/emoji).
  for (const auto& p : passes) {
    if (p.kind == PassKind::kPassthrough || p.extra_tex == 0) continue;
    glBindFramebuffer(GL_FRAMEBUFFER, cur_fbo);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, cur_tex);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, p.extra_tex);
    glUseProgram(prog_overlay_);
    glUniform1i(glGetUniformLocation(prog_overlay_, "u_src"), 0);
    glUniform1i(glGetUniformLocation(prog_overlay_, "u_layer"), 1);
    glUniform1f(glGetUniformLocation(prog_overlay_, "u_opacity"), p.opacity);
    glUniform1i(glGetUniformLocation(prog_overlay_, "u_blend"), p.blend_mode);
    draw_quad(prog_overlay_);
    GLuint tmp_tex = cur_tex; cur_tex = next_tex; next_tex = tmp_tex;
    cur_fbo = (cur_tex == tex_a_) ? fbo_b_ : fbo_a_;
  }

  output_tex_ = cur_tex;

  if (present) {
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, output_tex_);
    glUseProgram(prog_passthrough_);
    glUniform1i(glGetUniformLocation(prog_passthrough_, "u_src"), 0);
    draw_quad(prog_passthrough_);
  }
  check_err("execute");
}

void RenderGraph::destroy() {
  GLuint progs[] = {prog_passthrough_, prog_adjust_, prog_lut_, prog_crop_, prog_overlay_};
  for (GLuint p : progs) if (p) glDeleteProgram(p);
  prog_passthrough_ = prog_adjust_ = prog_lut_ = prog_crop_ = prog_overlay_ = 0;
  if (vbo_) { glDeleteBuffers(1, &vbo_); vbo_ = 0; }
  if (vao_) { glDeleteVertexArrays(1, &vao_); vao_ = 0; }
  if (tex_a_) { glDeleteTextures(1, &tex_a_); tex_a_ = 0; }
  if (tex_b_) { glDeleteTextures(1, &tex_b_); tex_b_ = 0; }
  if (fbo_a_) { glDeleteFramebuffers(1, &fbo_a_); fbo_a_ = 0; }
  if (fbo_b_) { glDeleteFramebuffers(1, &fbo_b_); fbo_b_ = 0; }
  base_tex_ = 0;
  output_tex_ = 0;
  width_ = 0;
  height_ = 0;
}

}  // namespace minis::imgedit
