// JNI bridge for VideoEditEngine.kt. Exposes the minimum surface needed by
// the MethodChannel handler:
//   - open / info / close on a probe session
//   - getCapabilities
//   - one-shot trim / concat / repair / thumbnail / export entry points
//
// Each call returns a Java Map<String, Object> with a stable schema; the
// Kotlin side forwards it straight to the Flutter result.

#include <jni.h>
#include <stdlib.h>
#include <string.h>

#include "ff_common.h"
#include "ff_session.h"

// Forward declarations from sibling files (defined in C4/C11/C12).
int ff_trim_run(const char* in_path, const char* out_path,
                int64_t in_ms, int64_t out_ms, int reencode,
                ff_progress_cb_t* cb);
int ff_concat_run(const char* const* in_paths, int n_paths,
                  const char* out_path, double speed, int keep_audio,
                  const char* music_path, int64_t music_in_ms, int64_t music_out_ms,
                  int keep_music_tempo,
                  ff_progress_cb_t* cb);
int ff_repair_run(const char* in_path, const char* out_path,
                  int target_height, ff_progress_cb_t* cb);
int ff_thumbstrip_run(const char* in_path, int count, int w, int h,
                      const char* out_dir, char*** out_paths, int* out_n);
int ff_export_run(const char* timeline_json, const char* preset,
                  const char* out_path, const char* options_json,
                  ff_progress_cb_t* cb);
int ff_export_cancel(const char* task_id);

// ──────────────────────────────────────────────────────────────────
// JNI helpers
// ──────────────────────────────────────────────────────────────────

static jstring jstr(JNIEnv* env, const char* s) {
  if (!s) return NULL;
  return (*env)->NewStringUTF(env, s);
}

static const char* cstr(JNIEnv* env, jstring s) {
  if (!s) return NULL;
  return (*env)->GetStringUTFChars(env, s, NULL);
}

static void freecstr(JNIEnv* env, jstring s, const char* c) {
  if (s && c) (*env)->ReleaseStringUTFChars(env, s, c);
}

// Build a java.util.HashMap and return as jobject.
static jobject new_hashmap(JNIEnv* env) {
  jclass cls = (*env)->FindClass(env, "java/util/HashMap");
  jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "()V");
  return (*env)->NewObject(env, cls, ctor);
}

static void map_put(JNIEnv* env, jobject map, const char* key, jobject value) {
  jclass cls = (*env)->GetObjectClass(env, map);
  jmethodID put = (*env)->GetMethodID(
      env, cls, "put",
      "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
  jstring jkey = jstr(env, key);
  (*env)->CallObjectMethod(env, map, put, jkey, value);
  (*env)->DeleteLocalRef(env, jkey);
}

static jobject box_int(JNIEnv* env, int v) {
  jclass cls = (*env)->FindClass(env, "java/lang/Integer");
  jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "(I)V");
  return (*env)->NewObject(env, cls, ctor, v);
}

static jobject box_long(JNIEnv* env, jlong v) {
  jclass cls = (*env)->FindClass(env, "java/lang/Long");
  jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "(J)V");
  return (*env)->NewObject(env, cls, ctor, v);
}

static jobject box_double(JNIEnv* env, double v) {
  jclass cls = (*env)->FindClass(env, "java/lang/Double");
  jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "(D)V");
  return (*env)->NewObject(env, cls, ctor, v);
}

static jobject box_bool(JNIEnv* env, int v) {
  jclass cls = (*env)->FindClass(env, "java/lang/Boolean");
  jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "(Z)V");
  return (*env)->NewObject(env, cls, ctor, v ? JNI_TRUE : JNI_FALSE);
}

// ──────────────────────────────────────────────────────────────────
// Progress dispatch — Kotlin attaches a global ref to a Java consumer
// (a kotlin.jvm.functions.Function2<String, java.util.Map, Unit>).
// We invoke `invoke(taskId, mapOfFields)` on each progress tick.
// ──────────────────────────────────────────────────────────────────

typedef struct jni_progress_ctx {
  JavaVM*   jvm;
  jobject   sink_global;
} jni_progress_ctx_t;

static void jni_progress_emit(void* user, const char* task_id,
                              const char* kind, double pct, double fps,
                              double eta_s) {
  jni_progress_ctx_t* ctx = (jni_progress_ctx_t*)user;
  if (!ctx || !ctx->jvm || !ctx->sink_global) return;
  JNIEnv* env = NULL;
  int attached = 0;
  if ((*ctx->jvm)->GetEnv(ctx->jvm, (void**)&env, JNI_VERSION_1_6) != JNI_OK) {
    if ((*ctx->jvm)->AttachCurrentThread(ctx->jvm, &env, NULL) != JNI_OK) return;
    attached = 1;
  }
  jobject map = new_hashmap(env);
  jstring jkind = jstr(env, kind ? kind : "");
  map_put(env, map, "kind", jkind);
  map_put(env, map, "pct", box_double(env, pct));
  map_put(env, map, "fps", box_double(env, fps));
  map_put(env, map, "etaS", box_double(env, eta_s));
  jstring jtask = jstr(env, task_id ? task_id : "");

  jclass cls = (*env)->GetObjectClass(env, ctx->sink_global);
  jmethodID invoke = (*env)->GetMethodID(
      env, cls, "invoke",
      "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
  if (invoke) {
    (*env)->CallObjectMethod(env, ctx->sink_global, invoke, jtask, map);
    if ((*env)->ExceptionCheck(env)) {
      (*env)->ExceptionDescribe(env);
      (*env)->ExceptionClear(env);
    }
  }
  (*env)->DeleteLocalRef(env, jkind);
  (*env)->DeleteLocalRef(env, jtask);
  (*env)->DeleteLocalRef(env, map);
  (*env)->DeleteLocalRef(env, cls);

  if (attached) (*ctx->jvm)->DetachCurrentThread(ctx->jvm);
}

// ──────────────────────────────────────────────────────────────────
// JNI exports
// ──────────────────────────────────────────────────────────────────

#define JNI_FN(name) \
  Java_com_loopit_minis_videdit_VideoEditEngine_##name

JNIEXPORT jlong JNICALL
JNI_FN(nativeOpen)(JNIEnv* env, jobject thiz, jstring jpath) {
  (void)thiz;
  const char* path = cstr(env, jpath);
  ff_session_t* s = ff_session_open(path);
  freecstr(env, jpath, path);
  return (jlong)(intptr_t)s;
}

JNIEXPORT jobject JNICALL
JNI_FN(nativeInfo)(JNIEnv* env, jobject thiz, jlong handle) {
  (void)thiz;
  ff_session_t* s = (ff_session_t*)(intptr_t)handle;
  if (!s) return NULL;
  ff_session_info_t info;
  if (ff_session_info_get(s, &info) != 0) return NULL;

  jobject map = new_hashmap(env);
  map_put(env, map, "durationMs", box_long(env, info.duration_ms));
  map_put(env, map, "width", box_int(env, info.width));
  map_put(env, map, "height", box_int(env, info.height));
  map_put(env, map, "fps", box_double(env, info.fps));
  map_put(env, map, "rotation", box_int(env, info.rotation));
  map_put(env, map, "bitrate", box_long(env, info.bitrate));
  map_put(env, map, "videoCodec", jstr(env, info.video_codec));
  map_put(env, map, "audioCodec", jstr(env, info.audio_codec));
  map_put(env, map, "hasAudio", box_bool(env, info.has_audio));
  map_put(env, map, "audioSampleRate", box_int(env, info.audio_sample_rate));
  map_put(env, map, "audioChannels", box_int(env, info.audio_channels));
  return map;
}

JNIEXPORT void JNICALL
JNI_FN(nativeClose)(JNIEnv* env, jobject thiz, jlong handle) {
  (void)env;
  (void)thiz;
  ff_session_close((ff_session_t*)(intptr_t)handle);
}

JNIEXPORT jobject JNICALL
JNI_FN(nativeCapabilities)(JNIEnv* env, jobject thiz) {
  (void)thiz;
  ff_capabilities_t c;
  ff_capabilities_query(&c);
  jobject map = new_hashmap(env);
  map_put(env, map, "hwDecH264", box_bool(env, c.hw_dec_h264));
  map_put(env, map, "hwDecHevc", box_bool(env, c.hw_dec_hevc));
  map_put(env, map, "hwDecVp9",  box_bool(env, c.hw_dec_vp9));
  map_put(env, map, "hwEncH264", box_bool(env, c.hw_enc_h264));
  map_put(env, map, "hwEncHevc", box_bool(env, c.hw_enc_hevc));
  map_put(env, map, "maxWidth",  box_int(env, c.max_resolution_w));
  map_put(env, map, "maxHeight", box_int(env, c.max_resolution_h));
  map_put(env, map, "ffmpegBuildInfo", jstr(env, c.build_info));
  return map;
}

JNIEXPORT jint JNICALL
JNI_FN(nativeTrim)(JNIEnv* env, jobject thiz,
                   jstring jin, jstring jout,
                   jlong inMs, jlong outMs, jboolean reencode,
                   jobject sink) {
  (void)thiz;
  const char* in = cstr(env, jin);
  const char* out = cstr(env, jout);
  jni_progress_ctx_t ctx = {0};
  ff_progress_cb_t cb = {0};
  if (sink) {
    (*env)->GetJavaVM(env, &ctx.jvm);
    ctx.sink_global = (*env)->NewGlobalRef(env, sink);
    cb.emit = jni_progress_emit;
    cb.user = &ctx;
  }
  int rc = ff_trim_run(in, out, (int64_t)inMs, (int64_t)outMs,
                       reencode ? 1 : 0, sink ? &cb : NULL);
  if (ctx.sink_global) (*env)->DeleteGlobalRef(env, ctx.sink_global);
  freecstr(env, jin, in);
  freecstr(env, jout, out);
  return rc;
}

JNIEXPORT jint JNICALL
JNI_FN(nativeConcat)(JNIEnv* env, jobject thiz,
                     jobjectArray jpaths, jstring jout,
                     jdouble speed, jboolean keepAudio,
                     jstring jmusic, jlong musicIn, jlong musicOut,
                     jboolean keepMusicTempo,
                     jobject sink) {
  (void)thiz;
  jsize n = (*env)->GetArrayLength(env, jpaths);
  const char** paths = (const char**)calloc((size_t)n, sizeof(char*));
  jstring* refs = (jstring*)calloc((size_t)n, sizeof(jstring));
  for (jsize i = 0; i < n; i++) {
    refs[i] = (jstring)(*env)->GetObjectArrayElement(env, jpaths, i);
    paths[i] = (*env)->GetStringUTFChars(env, refs[i], NULL);
  }
  const char* out = cstr(env, jout);
  const char* music = jmusic ? cstr(env, jmusic) : NULL;

  jni_progress_ctx_t ctx = {0};
  ff_progress_cb_t cb = {0};
  if (sink) {
    (*env)->GetJavaVM(env, &ctx.jvm);
    ctx.sink_global = (*env)->NewGlobalRef(env, sink);
    cb.emit = jni_progress_emit;
    cb.user = &ctx;
  }
  int rc = ff_concat_run(paths, (int)n, out, speed, keepAudio ? 1 : 0,
                         music, (int64_t)musicIn, (int64_t)musicOut,
                         keepMusicTempo ? 1 : 0,
                         sink ? &cb : NULL);
  if (ctx.sink_global) (*env)->DeleteGlobalRef(env, ctx.sink_global);

  for (jsize i = 0; i < n; i++) {
    (*env)->ReleaseStringUTFChars(env, refs[i], paths[i]);
    (*env)->DeleteLocalRef(env, refs[i]);
  }
  free(paths);
  free(refs);
  freecstr(env, jout, out);
  if (jmusic) freecstr(env, jmusic, music);
  return rc;
}

JNIEXPORT jint JNICALL
JNI_FN(nativeRepair)(JNIEnv* env, jobject thiz,
                     jstring jin, jstring jout, jint targetHeight,
                     jobject sink) {
  (void)thiz;
  const char* in = cstr(env, jin);
  const char* out = cstr(env, jout);
  jni_progress_ctx_t ctx = {0};
  ff_progress_cb_t cb = {0};
  if (sink) {
    (*env)->GetJavaVM(env, &ctx.jvm);
    ctx.sink_global = (*env)->NewGlobalRef(env, sink);
    cb.emit = jni_progress_emit;
    cb.user = &ctx;
  }
  int rc = ff_repair_run(in, out, (int)targetHeight, sink ? &cb : NULL);
  if (ctx.sink_global) (*env)->DeleteGlobalRef(env, ctx.sink_global);
  freecstr(env, jin, in);
  freecstr(env, jout, out);
  return rc;
}

JNIEXPORT jobjectArray JNICALL
JNI_FN(nativeThumbStrip)(JNIEnv* env, jobject thiz,
                         jstring jin, jint count, jint w, jint h,
                         jstring jcache_dir) {
  (void)thiz;
  const char* in = cstr(env, jin);
  const char* cache = cstr(env, jcache_dir);
  char** paths = NULL;
  int nout = 0;
  int rc = ff_thumbstrip_run(in, count, w, h, cache, &paths, &nout);
  freecstr(env, jin, in);
  freecstr(env, jcache_dir, cache);

  if (rc != 0 || !paths) return NULL;
  jclass strcls = (*env)->FindClass(env, "java/lang/String");
  jobjectArray arr = (*env)->NewObjectArray(env, nout, strcls, NULL);
  for (int i = 0; i < nout; i++) {
    jstring s = jstr(env, paths[i]);
    (*env)->SetObjectArrayElement(env, arr, i, s);
    (*env)->DeleteLocalRef(env, s);
    free(paths[i]);
  }
  free(paths);
  return arr;
}

JNIEXPORT jint JNICALL
JNI_FN(nativeExport)(JNIEnv* env, jobject thiz,
                     jstring jtimeline, jstring jpreset, jstring jout,
                     jstring joptions, jobject sink) {
  (void)thiz;
  const char* timeline = cstr(env, jtimeline);
  const char* preset = cstr(env, jpreset);
  const char* out = cstr(env, jout);
  const char* options = cstr(env, joptions);
  jni_progress_ctx_t ctx = {0};
  ff_progress_cb_t cb = {0};
  if (sink) {
    (*env)->GetJavaVM(env, &ctx.jvm);
    ctx.sink_global = (*env)->NewGlobalRef(env, sink);
    cb.emit = jni_progress_emit;
    cb.user = &ctx;
  }
  int rc = ff_export_run(timeline, preset, out, options, sink ? &cb : NULL);
  if (ctx.sink_global) (*env)->DeleteGlobalRef(env, ctx.sink_global);
  freecstr(env, jtimeline, timeline);
  freecstr(env, jpreset, preset);
  freecstr(env, jout, out);
  freecstr(env, joptions, options);
  return rc;
}

JNIEXPORT jint JNICALL
JNI_FN(nativeCancel)(JNIEnv* env, jobject thiz, jstring jtask) {
  (void)thiz;
  const char* t = cstr(env, jtask);
  int rc = ff_export_cancel(t);
  freecstr(env, jtask, t);
  return rc;
}

int ff_subtitles_burn(const char* in_path, const char* out_path,
                      const char* srt_path, const char* style,
                      ff_progress_cb_t* cb);
int ff_bg_compose_run(const char* in_path, const char* mask_atlas_path,
                      const char* bg_spec, const char* out_path,
                      ff_progress_cb_t* cb);
int ff_audio_mix_run(const char* const* audio_paths, int n_paths,
                     const char* filter_str, const char* out_path,
                     ff_progress_cb_t* cb);
int ff_av_remux_run(const char* video_path, const char* audio_path,
                    const char* out_path, ff_progress_cb_t* cb);

JNIEXPORT jint JNICALL
JNI_FN(nativeBurnCaptions)(JNIEnv* env, jobject thiz,
                           jstring jin, jstring jout, jstring jsrt, jstring jstyle,
                           jobject sink) {
  (void)thiz;
  const char* in = cstr(env, jin);
  const char* out = cstr(env, jout);
  const char* srt = cstr(env, jsrt);
  const char* style = cstr(env, jstyle);
  jni_progress_ctx_t ctx = {0};
  ff_progress_cb_t cb = {0};
  if (sink) {
    (*env)->GetJavaVM(env, &ctx.jvm);
    ctx.sink_global = (*env)->NewGlobalRef(env, sink);
    cb.emit = jni_progress_emit;
    cb.user = &ctx;
  }
  int rc = ff_subtitles_burn(in, out, srt, style, sink ? &cb : NULL);
  if (ctx.sink_global) (*env)->DeleteGlobalRef(env, ctx.sink_global);
  freecstr(env, jin, in);
  freecstr(env, jout, out);
  freecstr(env, jsrt, srt);
  freecstr(env, jstyle, style);
  return rc;
}

JNIEXPORT jint JNICALL
JNI_FN(nativeComposeBackground)(JNIEnv* env, jobject thiz,
                                jstring jin, jstring jatlas, jstring jbg, jstring jout,
                                jobject sink) {
  (void)thiz;
  const char* in = cstr(env, jin);
  const char* atlas = cstr(env, jatlas);
  const char* bg = cstr(env, jbg);
  const char* out = cstr(env, jout);
  jni_progress_ctx_t ctx = {0};
  ff_progress_cb_t cb = {0};
  if (sink) {
    (*env)->GetJavaVM(env, &ctx.jvm);
    ctx.sink_global = (*env)->NewGlobalRef(env, sink);
    cb.emit = jni_progress_emit;
    cb.user = &ctx;
  }
  int rc = ff_bg_compose_run(in, atlas, bg, out, sink ? &cb : NULL);
  if (ctx.sink_global) (*env)->DeleteGlobalRef(env, ctx.sink_global);
  freecstr(env, jin, in);
  freecstr(env, jatlas, atlas);
  freecstr(env, jbg, bg);
  freecstr(env, jout, out);
  return rc;
}

JNIEXPORT jint JNICALL
JNI_FN(nativeMixAudio)(JNIEnv* env, jobject thiz,
                       jobjectArray jpaths, jstring jfilter, jstring jout,
                       jobject sink) {
  (void)thiz;
  jsize n = (*env)->GetArrayLength(env, jpaths);
  const char** paths = (const char**)calloc((size_t)n, sizeof(char*));
  jstring* refs = (jstring*)calloc((size_t)n, sizeof(jstring));
  for (jsize i = 0; i < n; i++) {
    refs[i] = (jstring)(*env)->GetObjectArrayElement(env, jpaths, i);
    paths[i] = (*env)->GetStringUTFChars(env, refs[i], NULL);
  }
  const char* filter = cstr(env, jfilter);
  const char* out = cstr(env, jout);
  jni_progress_ctx_t ctx = {0};
  ff_progress_cb_t cb = {0};
  if (sink) {
    (*env)->GetJavaVM(env, &ctx.jvm);
    ctx.sink_global = (*env)->NewGlobalRef(env, sink);
    cb.emit = jni_progress_emit;
    cb.user = &ctx;
  }
  int rc = ff_audio_mix_run(paths, (int)n, filter, out, sink ? &cb : NULL);
  if (ctx.sink_global) (*env)->DeleteGlobalRef(env, ctx.sink_global);
  for (jsize i = 0; i < n; i++) {
    (*env)->ReleaseStringUTFChars(env, refs[i], paths[i]);
    (*env)->DeleteLocalRef(env, refs[i]);
  }
  free(paths);
  free(refs);
  freecstr(env, jfilter, filter);
  freecstr(env, jout, out);
  return rc;
}

JNIEXPORT jint JNICALL
JNI_FN(nativeReplaceAudio)(JNIEnv* env, jobject thiz,
                           jstring jvideo, jstring jaudio, jstring jout,
                           jobject sink) {
  (void)thiz;
  const char* v = cstr(env, jvideo);
  const char* a = cstr(env, jaudio);
  const char* out = cstr(env, jout);
  jni_progress_ctx_t ctx = {0};
  ff_progress_cb_t cb = {0};
  if (sink) {
    (*env)->GetJavaVM(env, &ctx.jvm);
    ctx.sink_global = (*env)->NewGlobalRef(env, sink);
    cb.emit = jni_progress_emit;
    cb.user = &ctx;
  }
  int rc = ff_av_remux_run(v, a, out, sink ? &cb : NULL);
  if (ctx.sink_global) (*env)->DeleteGlobalRef(env, ctx.sink_global);
  freecstr(env, jvideo, v);
  freecstr(env, jaudio, a);
  freecstr(env, jout, out);
  return rc;
}
