// EGL context bound to an ANativeWindow.
// Single-thread owner; thread-safe init/teardown.

#pragma once

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <android/native_window.h>
#include <cstdint>

namespace minis::imgedit {

class EglContext {
 public:
  EglContext();
  ~EglContext();

  bool init(ANativeWindow* window);
  void resize(int32_t w, int32_t h);
  void destroy();

  bool make_current();
  bool swap_buffers();

  int32_t width() const { return width_; }
  int32_t height() const { return height_; }
  bool valid() const { return display_ != EGL_NO_DISPLAY && surface_ != EGL_NO_SURFACE; }

 private:
  EGLDisplay display_{EGL_NO_DISPLAY};
  EGLSurface surface_{EGL_NO_SURFACE};
  EGLContext context_{EGL_NO_CONTEXT};
  EGLConfig  config_{nullptr};
  ANativeWindow* window_{nullptr};
  int32_t width_{0};
  int32_t height_{0};
};

}  // namespace minis::imgedit
