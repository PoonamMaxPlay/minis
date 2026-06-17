#include "egl_context.h"

#include <android/log.h>

#define LOG_TAG "MinisImgEditEgl"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace minis::imgedit {

EglContext::EglContext() = default;
EglContext::~EglContext() { destroy(); }

bool EglContext::init(ANativeWindow* window) {
  if (window == nullptr) return false;
  destroy();

  window_ = window;
  ANativeWindow_acquire(window_);

  display_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (display_ == EGL_NO_DISPLAY) {
    LOGE("eglGetDisplay failed");
    return false;
  }
  EGLint major = 0, minor = 0;
  if (!eglInitialize(display_, &major, &minor)) {
    LOGE("eglInitialize failed");
    return false;
  }

  const EGLint cfg_attrs[] = {
    EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
    EGL_RED_SIZE, 8,
    EGL_GREEN_SIZE, 8,
    EGL_BLUE_SIZE, 8,
    EGL_ALPHA_SIZE, 8,
    EGL_DEPTH_SIZE, 0,
    EGL_STENCIL_SIZE, 0,
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
    EGL_NONE
  };
  EGLint num_cfg = 0;
  if (!eglChooseConfig(display_, cfg_attrs, &config_, 1, &num_cfg) || num_cfg <= 0) {
    LOGE("eglChooseConfig failed");
    return false;
  }

  EGLint format = 0;
  eglGetConfigAttrib(display_, config_, EGL_NATIVE_VISUAL_ID, &format);
  ANativeWindow_setBuffersGeometry(window_, 0, 0, format);

  surface_ = eglCreateWindowSurface(display_, config_, window_, nullptr);
  if (surface_ == EGL_NO_SURFACE) {
    LOGE("eglCreateWindowSurface failed");
    return false;
  }

  const EGLint ctx_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
  context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT, ctx_attrs);
  if (context_ == EGL_NO_CONTEXT) {
    LOGE("eglCreateContext failed");
    return false;
  }

  if (!eglMakeCurrent(display_, surface_, surface_, context_)) {
    LOGE("eglMakeCurrent failed");
    return false;
  }

  eglQuerySurface(display_, surface_, EGL_WIDTH, &width_);
  eglQuerySurface(display_, surface_, EGL_HEIGHT, &height_);
  LOGI("EGL ready %d.%d %dx%d", major, minor, width_, height_);
  return true;
}

void EglContext::resize(int32_t w, int32_t h) {
  width_ = w;
  height_ = h;
}

bool EglContext::make_current() {
  if (display_ == EGL_NO_DISPLAY || context_ == EGL_NO_CONTEXT) return false;
  return eglMakeCurrent(display_, surface_, surface_, context_);
}

bool EglContext::swap_buffers() {
  if (display_ == EGL_NO_DISPLAY || surface_ == EGL_NO_SURFACE) return false;
  return eglSwapBuffers(display_, surface_);
}

void EglContext::destroy() {
  if (display_ != EGL_NO_DISPLAY) {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
    if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, surface_);
    eglTerminate(display_);
  }
  display_ = EGL_NO_DISPLAY;
  surface_ = EGL_NO_SURFACE;
  context_ = EGL_NO_CONTEXT;
  config_ = nullptr;
  if (window_ != nullptr) {
    ANativeWindow_release(window_);
    window_ = nullptr;
  }
  width_ = 0;
  height_ = 0;
}

}  // namespace minis::imgedit
