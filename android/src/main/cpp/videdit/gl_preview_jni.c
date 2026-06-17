// JNI surface for VideoEditNativePreview.kt + render thread that drives
// the GL compositor against the attached `Surface`.
//
// `attachSurface` does the heavy lift:
//   1. Wrap the Java `Surface` as an `ANativeWindow`.
//   2. Build an EGL display + GLES3 context + window surface.
//   3. Spawn a render thread whose job is to call `eglMakeCurrent`, render
//      one compositor frame per tick at 60 Hz, and `eglSwapBuffers`.
//
// The compositor instance lives in gl_compositor.cpp. The host wires
// per-clip textures via `gl_compositor_draw`; this file owns the EGL
// boilerplate and the render thread lifecycle.

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <pthread.h>

#include "ff_common.h"

// Compositor C surface (gl_compositor.cpp).
void* gl_compositor_create(int width, int height);
void  gl_compositor_destroy(void* handle);
void  gl_compositor_draw(void* handle, unsigned tex_a, unsigned tex_b,
                         const char* transition, float progress,
                         const float* transform, unsigned lut3d, float lut_amount);
void  gl_compositor_set_clip_texture(void* handle, int slot, unsigned oes_tex_id);
void  gl_compositor_draw_oes(void* handle, const char* transition, float progress,
                             const float* transform, unsigned lut3d, float lut_amount);

typedef struct preview_session {
  ANativeWindow* window;
  EGLDisplay display;
  EGLConfig config;
  EGLContext context;
  EGLSurface surface;
  int width;
  int height;
  void* compositor;             // owned
  pthread_t render_thread;
  volatile int running;
  pthread_mutex_t lock;
} preview_session_t;

#define MAX_PREVIEW 4
static preview_session_t* g_sessions[MAX_PREVIEW] = {0};
static pthread_mutex_t g_table_lock = PTHREAD_MUTEX_INITIALIZER;

static int find_slot_locked(jlong view_id) {
  for (int i = 0; i < MAX_PREVIEW; i++) {
    if (g_sessions[i] && (jlong)(intptr_t)g_sessions[i] == view_id) return i;
  }
  return -1;
}

static int alloc_slot_locked(void) {
  for (int i = 0; i < MAX_PREVIEW; i++) {
    if (!g_sessions[i]) return i;
  }
  return -1;
}

static int egl_init(preview_session_t* s) {
  s->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (s->display == EGL_NO_DISPLAY) return -1;
  if (!eglInitialize(s->display, NULL, NULL)) return -1;

  const EGLint attrs[] = {
    EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
    EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
    EGL_NONE,
  };
  EGLint n_configs = 0;
  if (!eglChooseConfig(s->display, attrs, &s->config, 1, &n_configs) || n_configs < 1) {
    return -1;
  }
  const EGLint ctx_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
  s->context = eglCreateContext(s->display, s->config, EGL_NO_CONTEXT, ctx_attrs);
  if (s->context == EGL_NO_CONTEXT) return -1;
  s->surface = eglCreateWindowSurface(s->display, s->config, s->window, NULL);
  if (s->surface == EGL_NO_SURFACE) return -1;
  return 0;
}

static void egl_destroy(preview_session_t* s) {
  if (s->display != EGL_NO_DISPLAY) {
    eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (s->surface) eglDestroySurface(s->display, s->surface);
    if (s->context) eglDestroyContext(s->display, s->context);
    eglTerminate(s->display);
  }
  if (s->window) ANativeWindow_release(s->window);
  s->display = EGL_NO_DISPLAY;
  s->context = EGL_NO_CONTEXT;
  s->surface = EGL_NO_SURFACE;
  s->window = NULL;
}

static void* render_thread_fn(void* arg) {
  preview_session_t* s = (preview_session_t*)arg;
  if (!eglMakeCurrent(s->display, s->surface, s->surface, s->context)) {
    FF_LOGE("gl_preview: eglMakeCurrent failed on render thread");
    return NULL;
  }
  s->compositor = gl_compositor_create(s->width, s->height);
  if (!s->compositor) {
    FF_LOGE("gl_preview: compositor_create failed");
    return NULL;
  }

  const float identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  struct timespec frame_interval = { 0, 16 * 1000 * 1000 };  // ~60 Hz

  while (s->running) {
    pthread_mutex_lock(&s->lock);
    void* comp = s->compositor;
    int w = s->width;
    int h = s->height;
    pthread_mutex_unlock(&s->lock);
    if (!comp) break;

    glViewport(0, 0, w, h);
    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);
    // Host hands current clip textures to the compositor via the
    // `attachClipTexture` JNI verb (TimelineOrchestrator.kt drives this).
    // The OES draw path samples the SurfaceTexture directly; the compositor
    // degrades to the 2D draw when no clip is set.
    gl_compositor_draw_oes(comp, "", 0.f, identity, 0u, 0.f);
    eglSwapBuffers(s->display, s->surface);

    nanosleep(&frame_interval, NULL);
  }

  if (s->compositor) {
    gl_compositor_destroy(s->compositor);
    s->compositor = NULL;
  }
  eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  return NULL;
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_videdit_VideoEditNativePreview_nativeAttachSurface(
    JNIEnv* env, jobject thiz, jlong view_id, jobject jsurface, jint w, jint h) {
  (void)thiz;
  pthread_mutex_lock(&g_table_lock);
  int slot = find_slot_locked(view_id);
  if (slot < 0) slot = alloc_slot_locked();
  if (slot < 0) { pthread_mutex_unlock(&g_table_lock); return; }
  preview_session_t* s = g_sessions[slot];
  if (!s) {
    s = (preview_session_t*)calloc(1, sizeof(*s));
    pthread_mutex_init(&s->lock, NULL);
    g_sessions[slot] = s;
  }
  pthread_mutex_unlock(&g_table_lock);

  pthread_mutex_lock(&s->lock);
  if (s->running) {
    s->running = 0;
    pthread_mutex_unlock(&s->lock);
    pthread_join(s->render_thread, NULL);
    pthread_mutex_lock(&s->lock);
  }
  if (s->window) {
    egl_destroy(s);
  }
  s->window = ANativeWindow_fromSurface(env, jsurface);
  s->width = w;
  s->height = h;
  if (!s->window || egl_init(s) != 0) {
    FF_LOGE("gl_preview: egl_init failed");
    egl_destroy(s);
    pthread_mutex_unlock(&s->lock);
    return;
  }
  s->running = 1;
  pthread_mutex_unlock(&s->lock);
  pthread_create(&s->render_thread, NULL, render_thread_fn, s);
  FF_LOGI("gl_preview: render thread started (viewId=%lld, %dx%d)", (long long)view_id, w, h);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_videdit_VideoEditNativePreview_nativeResizeSurface(
    JNIEnv* env, jobject thiz, jlong view_id, jint w, jint h) {
  (void)env; (void)thiz;
  pthread_mutex_lock(&g_table_lock);
  int slot = find_slot_locked(view_id);
  pthread_mutex_unlock(&g_table_lock);
  if (slot < 0) return;
  preview_session_t* s = g_sessions[slot];
  pthread_mutex_lock(&s->lock);
  s->width = w;
  s->height = h;
  pthread_mutex_unlock(&s->lock);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_videdit_VideoEditNativePreview_nativeSetClipTexture(
    JNIEnv* env, jobject thiz, jlong view_id, jint slot, jint oes_tex) {
  (void)env; (void)thiz;
  pthread_mutex_lock(&g_table_lock);
  int idx = find_slot_locked(view_id);
  pthread_mutex_unlock(&g_table_lock);
  if (idx < 0) return;
  preview_session_t* s = g_sessions[idx];
  pthread_mutex_lock(&s->lock);
  if (s->compositor) {
    gl_compositor_set_clip_texture(s->compositor, (int)slot, (unsigned)oes_tex);
  }
  pthread_mutex_unlock(&s->lock);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_videdit_VideoEditNativePreview_nativeDetachSurface(
    JNIEnv* env, jobject thiz, jlong view_id) {
  (void)env; (void)thiz;
  pthread_mutex_lock(&g_table_lock);
  int slot = find_slot_locked(view_id);
  preview_session_t* s = slot >= 0 ? g_sessions[slot] : NULL;
  if (slot >= 0) g_sessions[slot] = NULL;
  pthread_mutex_unlock(&g_table_lock);
  if (!s) return;

  pthread_mutex_lock(&s->lock);
  s->running = 0;
  pthread_mutex_unlock(&s->lock);
  pthread_join(s->render_thread, NULL);

  pthread_mutex_lock(&s->lock);
  egl_destroy(s);
  pthread_mutex_unlock(&s->lock);
  pthread_mutex_destroy(&s->lock);
  free(s);
}
