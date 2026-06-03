// GL ES compositor (preview-time).
//
// Architecture (improvement3.md §C5):
//   - Each active clip surface is decoded by MediaCodec into an
//     OES external texture that this compositor samples.
//   - Per-clip uniforms: transform (3x3), LUT (3D texture), corner_radius.
//   - Pair of clips driven through a transition shader during overlap.
//   - Final FBO is exposed to Flutter via a SurfaceTexture handed back to
//     `VideoEditPlatformView`.
//
// This file ships the program/FBO management. Per-effect fragment shaders
// live under shaders/ and are loaded by name from the timeline's
// transition/transform metadata.

#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <EGL/egl.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "ff_common.h"

#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif

namespace minis_videdit {

namespace {

constexpr const char* kBaseVertexSrc = R"(
#version 300 es
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
uniform mat3 u_transform;
out vec2 v_uv;
void main() {
  vec3 p = u_transform * vec3(a_pos, 1.0);
  gl_Position = vec4(p.xy, 0.0, 1.0);
  v_uv = a_uv;
}
)";

constexpr const char* kPassThroughFragSrc = R"(
#version 300 es
precision mediump float;
in vec2 v_uv;
uniform sampler2D u_tex;
uniform float u_lut_amount;
uniform sampler3D u_lut;
out vec4 frag;
void main() {
  vec3 c = texture(u_tex, v_uv).rgb;
  vec3 graded = texture(u_lut, c).rgb;
  frag = vec4(mix(c, graded, u_lut_amount), 1.0);
}
)";

// Samples a MediaCodec-backed OES external texture. Used when the host
// hands a `SurfaceTexture` (wrapped as a GL_TEXTURE_EXTERNAL_OES handle)
// directly into the compositor instead of pre-blitting into a 2D texture.
constexpr const char* kOesFragSrc = R"(
#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in vec2 v_uv;
uniform samplerExternalOES u_tex_oes;
uniform float u_lut_amount;
uniform sampler3D u_lut;
out vec4 frag;
void main() {
  vec3 c = texture(u_tex_oes, v_uv).rgb;
  vec3 graded = texture(u_lut, c).rgb;
  frag = vec4(mix(c, graded, u_lut_amount), 1.0);
}
)";

GLuint compile_shader(GLenum type, const char* src) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, nullptr);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[512];
    glGetShaderInfoLog(s, sizeof(log), nullptr, log);
    FF_LOGE("gl_compositor: shader compile failed: %s", log);
    glDeleteShader(s);
    return 0;
  }
  return s;
}

GLuint link_program(GLuint vs, GLuint fs) {
  GLuint p = glCreateProgram();
  glAttachShader(p, vs);
  glAttachShader(p, fs);
  glLinkProgram(p);
  GLint ok = 0;
  glGetProgramiv(p, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[512];
    glGetProgramInfoLog(p, sizeof(log), nullptr, log);
    FF_LOGE("gl_compositor: link failed: %s", log);
    glDeleteProgram(p);
    return 0;
  }
  return p;
}

}  // namespace

class Compositor {
 public:
  Compositor() = default;
  ~Compositor() { destroy(); }

  bool init(int width, int height) {
    width_ = width;
    height_ = height;

    GLuint vs = compile_shader(GL_VERTEX_SHADER, kBaseVertexSrc);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, kPassThroughFragSrc);
    program_ = link_program(vs, fs);
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!program_) return false;

    // OES external sampler program. Lazy-init: many devices ship the
    // extension but a few cheap GPUs reject the parser at link time, so
    // we degrade to the 2D sampler when this fails.
    GLuint oes_vs = compile_shader(GL_VERTEX_SHADER, kBaseVertexSrc);
    GLuint oes_fs = compile_shader(GL_FRAGMENT_SHADER, kOesFragSrc);
    if (oes_fs) {
      program_oes_ = link_program(oes_vs, oes_fs);
    }
    if (oes_vs) glDeleteShader(oes_vs);
    if (oes_fs) glDeleteShader(oes_fs);

    glGenFramebuffers(1, &fbo_);
    glGenTextures(1, &fbo_tex_);
    glBindTexture(GL_TEXTURE_2D, fbo_tex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, fbo_tex_, 0);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  }

  void destroy() {
    if (fbo_tex_) glDeleteTextures(1, &fbo_tex_);
    if (fbo_)     glDeleteFramebuffers(1, &fbo_);
    if (program_) glDeleteProgram(program_);
    if (program_oes_) glDeleteProgram(program_oes_);
    fbo_ = fbo_tex_ = program_ = program_oes_ = 0;
    for (auto& kv : transition_programs_) glDeleteProgram(kv.second);
    transition_programs_.clear();
  }

  // Host pushes the current OES texture (a SurfaceTexture-backed external
  // texture name from HWDecoderPool) for clip slot A or B. The render loop
  // samples whichever is set via `draw_with_oes`.
  void set_clip_texture(int slot, GLuint oes_tex_id) {
    std::lock_guard<std::mutex> lk(clips_mu_);
    if (slot == 0) clip_a_oes_ = oes_tex_id;
    else if (slot == 1) clip_b_oes_ = oes_tex_id;
  }

  // Renders frameA (or frameA blended with frameB through `transition`)
  // into the FBO. `progress` is the transition position in [0, 1].
  void draw(GLuint tex_a, GLuint tex_b, const char* transition,
            float progress, const float transform[9], GLuint lut3d, float lut_amount) {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glViewport(0, 0, width_, height_);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    GLuint prog = program_;
    if (transition && transition[0] && tex_b != 0) {
      auto it = transition_programs_.find(transition);
      if (it != transition_programs_.end()) prog = it->second;
    }
    glUseProgram(prog);

    GLint loc_tex = glGetUniformLocation(prog, "u_tex");
    GLint loc_texB = glGetUniformLocation(prog, "u_texB");
    GLint loc_progress = glGetUniformLocation(prog, "u_progress");
    GLint loc_transform = glGetUniformLocation(prog, "u_transform");
    GLint loc_lut = glGetUniformLocation(prog, "u_lut");
    GLint loc_lut_amt = glGetUniformLocation(prog, "u_lut_amount");

    if (loc_transform >= 0) glUniformMatrix3fv(loc_transform, 1, GL_FALSE, transform);
    if (loc_progress >= 0) glUniform1f(loc_progress, progress);
    if (loc_lut_amt >= 0) glUniform1f(loc_lut_amt, lut_amount);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex_a);
    if (loc_tex >= 0) glUniform1i(loc_tex, 0);

    if (tex_b != 0 && loc_texB >= 0) {
      glActiveTexture(GL_TEXTURE1);
      glBindTexture(GL_TEXTURE_2D, tex_b);
      glUniform1i(loc_texB, 1);
    }
    if (lut3d != 0 && loc_lut >= 0) {
      glActiveTexture(GL_TEXTURE2);
      glBindTexture(GL_TEXTURE_3D, lut3d);
      glUniform1i(loc_lut, 2);
    }
    draw_unit_quad();
  }

  // Draws the current clip pair sampling from the host-supplied OES
  // textures. Falls back to the regular 2D draw when OES program is not
  // available or no clip texture has been set yet.
  void draw_with_oes(const char* transition, float progress,
                     const float transform[9], GLuint lut3d, float lut_amount) {
    GLuint tex_a, tex_b;
    {
      std::lock_guard<std::mutex> lk(clips_mu_);
      tex_a = clip_a_oes_;
      tex_b = clip_b_oes_;
    }
    if (program_oes_ == 0 || tex_a == 0) {
      draw(tex_a, tex_b, transition, progress, transform, lut3d, lut_amount);
      return;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glViewport(0, 0, width_, height_);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(program_oes_);
    GLint loc_tex_oes = glGetUniformLocation(program_oes_, "u_tex_oes");
    GLint loc_lut = glGetUniformLocation(program_oes_, "u_lut");
    GLint loc_lut_amt = glGetUniformLocation(program_oes_, "u_lut_amount");
    GLint loc_transform = glGetUniformLocation(program_oes_, "u_transform");
    if (loc_transform >= 0) glUniformMatrix3fv(loc_transform, 1, GL_FALSE, transform);
    if (loc_lut_amt >= 0) glUniform1f(loc_lut_amt, lut_amount);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, tex_a);
    if (loc_tex_oes >= 0) glUniform1i(loc_tex_oes, 0);
    if (lut3d != 0 && loc_lut >= 0) {
      glActiveTexture(GL_TEXTURE2);
      glBindTexture(GL_TEXTURE_3D, lut3d);
      glUniform1i(loc_lut, 2);
    }
    draw_unit_quad();
    (void)transition; (void)progress; (void)tex_b;
    // Phase 4.x: two-OES blend path uses the transition program with two
    // samplerExternalOES inputs. For now single-clip OES draw is enough
    // for the basic preview path.
  }

  bool add_transition(const char* name, const char* frag_src) {
    if (!name || !frag_src) return false;
    if (transition_programs_.count(name)) return true;
    GLuint vs = compile_shader(GL_VERTEX_SHADER, kBaseVertexSrc);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, frag_src);
    GLuint p = link_program(vs, fs);
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!p) return false;
    transition_programs_[name] = p;
    return true;
  }

 private:
  void draw_unit_quad() {
    static const float quad[] = {
      -1.f, -1.f, 0.f, 0.f,
       1.f, -1.f, 1.f, 0.f,
      -1.f,  1.f, 0.f, 1.f,
       1.f,  1.f, 1.f, 1.f,
    };
    static GLuint vbo = 0;
    if (!vbo) {
      glGenBuffers(1, &vbo);
      glBindBuffer(GL_ARRAY_BUFFER, vbo);
      glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    }
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(float) * 4, (void*)0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(float) * 4, (void*)(sizeof(float) * 2));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  }

  int width_ = 0;
  int height_ = 0;
  GLuint program_ = 0;
  GLuint program_oes_ = 0;
  GLuint fbo_ = 0;
  GLuint fbo_tex_ = 0;
  std::unordered_map<std::string, GLuint> transition_programs_;
  std::mutex clips_mu_;
  GLuint clip_a_oes_ = 0;
  GLuint clip_b_oes_ = 0;
};

}  // namespace minis_videdit

// Public C surface — the Kotlin side (Phase 2.5) holds an opaque pointer
// to the compositor instance and routes timeline events here.
extern "C" {

void* gl_compositor_create(int width, int height) {
  auto* c = new minis_videdit::Compositor();
  if (!c->init(width, height)) {
    delete c;
    return nullptr;
  }
  return c;
}

void gl_compositor_destroy(void* handle) {
  delete static_cast<minis_videdit::Compositor*>(handle);
}

int gl_compositor_add_transition(void* handle, const char* name, const char* frag_src) {
  if (!handle) return -1;
  auto* c = static_cast<minis_videdit::Compositor*>(handle);
  return c->add_transition(name, frag_src) ? 0 : -1;
}

void gl_compositor_draw(void* handle, unsigned tex_a, unsigned tex_b,
                        const char* transition, float progress,
                        const float* transform, unsigned lut3d, float lut_amount) {
  if (!handle || !transform) return;
  static_cast<minis_videdit::Compositor*>(handle)->draw(
      tex_a, tex_b, transition, progress, transform, lut3d, lut_amount);
}

void gl_compositor_set_clip_texture(void* handle, int slot, unsigned oes_tex_id) {
  if (!handle) return;
  static_cast<minis_videdit::Compositor*>(handle)->set_clip_texture(slot, oes_tex_id);
}

void gl_compositor_draw_oes(void* handle, const char* transition, float progress,
                            const float* transform, unsigned lut3d, float lut_amount) {
  if (!handle || !transform) return;
  static_cast<minis_videdit::Compositor*>(handle)->draw_with_oes(
      transition, progress, transform, lut3d, lut_amount);
}

}  // extern "C"
