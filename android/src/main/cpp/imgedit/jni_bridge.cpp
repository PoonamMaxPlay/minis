// JNI bridge. Exports the symbols expected by `ImageEditNative.kt`.
// Marshals Kotlin `Map<String, Any?>` arg payloads via JNI map iteration.

#include "pipeline.h"
#include "heal.h"
#include "liquify.h"

#include <jni.h>
#include <android/bitmap.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <GLES3/gl3.h>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#define LOG_TAG "MinisImgEditJni"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

using namespace minis::imgedit;

std::shared_ptr<Session> get_or_create(int32_t view_id, const std::string& src,
                                       int32_t w, int32_t h) {
  auto s = get_session(view_id);
  if (!s) s = create_session(view_id, src, w, h);
  return s;
}

std::string jstr(JNIEnv* env, jstring s) {
  if (s == nullptr) return {};
  const char* c = env->GetStringUTFChars(s, nullptr);
  std::string out(c ? c : "");
  if (c) env->ReleaseStringUTFChars(s, c);
  return out;
}

// Returns key -> value (as jobject) for a single key in a Map.
jobject map_get(JNIEnv* env, jobject map, const char* key) {
  if (map == nullptr) return nullptr;
  jclass mapCls = env->GetObjectClass(map);
  jmethodID get = env->GetMethodID(mapCls, "get",
                                   "(Ljava/lang/Object;)Ljava/lang/Object;");
  jstring k = env->NewStringUTF(key);
  jobject v = env->CallObjectMethod(map, get, k);
  env->DeleteLocalRef(k);
  env->DeleteLocalRef(mapCls);
  return v;
}

double obj_to_double(JNIEnv* env, jobject o, double def = 0.0) {
  if (o == nullptr) return def;
  jclass num = env->FindClass("java/lang/Number");
  jmethodID m = env->GetMethodID(num, "doubleValue", "()D");
  double d = env->CallDoubleMethod(o, m);
  env->DeleteLocalRef(num);
  return d;
}

int obj_to_int(JNIEnv* env, jobject o, int def = 0) {
  if (o == nullptr) return def;
  jclass num = env->FindClass("java/lang/Number");
  jmethodID m = env->GetMethodID(num, "intValue", "()I");
  int v = env->CallIntMethod(o, m);
  env->DeleteLocalRef(num);
  return v;
}

std::string obj_to_string(JNIEnv* env, jobject o) {
  if (o == nullptr) return {};
  return jstr(env, (jstring)o);
}

// Upload an android.graphics.Bitmap into the session base texture.
void upload_bitmap_to_base(JNIEnv* env, jobject bitmap, int32_t view_id) {
  if (bitmap == nullptr) return;
  AndroidBitmapInfo info;
  if (AndroidBitmap_getInfo(env, bitmap, &info) < 0) return;
  if (info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) return;
  void* pixels = nullptr;
  if (AndroidBitmap_lockPixels(env, bitmap, &pixels) < 0) return;
  auto sess = get_session(view_id);
  // SessionImpl is the only impl; expose set_base_pixels via virtual? No.
  // We use a static cast through the registry helper declared in pipeline.cpp.
  // For simplicity we route via apply_filter("") + manual base swap is not
  // available, so we drop bytes for now if Session can't accept them.
  (void)sess;
  (void)pixels;
  (void)info;
  AndroidBitmap_unlockPixels(env, bitmap);
}

}  // namespace

extern "C" {

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeInitSession(
    JNIEnv* env, jobject /*thiz*/, jint view_id, jstring source_path,
    jint w, jint h) {
  std::string src = jstr(env, source_path);
  create_session(view_id, src, w, h);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeDisposeView(
    JNIEnv* /*env*/, jobject /*thiz*/, jint view_id) {
  destroy_session(view_id);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeSurfaceCreated(
    JNIEnv* env, jobject /*thiz*/, jint view_id, jobject surface) {
  auto s = get_or_create(view_id, {}, 0, 0);
  if (!s) return;
  ANativeWindow* win = ANativeWindow_fromSurface(env, surface);
  if (win == nullptr) {
    LOGE("ANativeWindow_fromSurface null");
    return;
  }
  s->surface_created(win);
  ANativeWindow_release(win);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeSurfaceChanged(
    JNIEnv* /*env*/, jobject /*thiz*/, jint view_id, jint w, jint h) {
  auto s = get_session(view_id);
  if (s) s->surface_changed(w, h);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeSurfaceDestroyed(
    JNIEnv* /*env*/, jobject /*thiz*/, jint view_id) {
  auto s = get_session(view_id);
  if (s) s->surface_destroyed();
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeRequestRender(
    JNIEnv* /*env*/, jobject /*thiz*/, jint view_id) {
  auto s = get_session(view_id);
  if (s) s->request_render();
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeApplyAdjust(
    JNIEnv* env, jobject /*thiz*/, jint view_id, jstring key, jdouble value) {
  auto s = get_session(view_id);
  if (!s) return;
  AdjustParams p;
  p.key = jstr(env, key);
  p.value = value;
  s->apply_adjust(p);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeApplyFilter(
    JNIEnv* env, jobject /*thiz*/, jint view_id, jstring lut_path,
    jdouble intensity) {
  auto s = get_session(view_id);
  if (!s) return;
  LutParams p;
  p.path = jstr(env, lut_path);
  p.intensity = intensity;
  s->apply_filter(p);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeApplyCrop(
    JNIEnv* env, jobject /*thiz*/, jint view_id, jobject rect_map,
    jdouble rotation_deg, jobject persp_list) {
  auto s = get_session(view_id);
  if (!s) return;
  CropParams cp;
  cp.rotation_deg = rotation_deg;
  if (rect_map != nullptr) {
    jobject xo = map_get(env, rect_map, "x");
    jobject yo = map_get(env, rect_map, "y");
    jobject wo = map_get(env, rect_map, "w");
    jobject ho = map_get(env, rect_map, "h");
    cp.rect.x = (float)obj_to_double(env, xo);
    cp.rect.y = (float)obj_to_double(env, yo);
    cp.rect.w = (float)obj_to_double(env, wo, 1.0);
    cp.rect.h = (float)obj_to_double(env, ho, 1.0);
    if (xo) env->DeleteLocalRef(xo);
    if (yo) env->DeleteLocalRef(yo);
    if (wo) env->DeleteLocalRef(wo);
    if (ho) env->DeleteLocalRef(ho);
  }
  if (persp_list != nullptr) {
    jclass list = env->FindClass("java/util/List");
    jmethodID sz = env->GetMethodID(list, "size", "()I");
    jmethodID get = env->GetMethodID(list, "get", "(I)Ljava/lang/Object;");
    int n = env->CallIntMethod(persp_list, sz);
    for (int i = 0; i < n; ++i) {
      jobject v = env->CallObjectMethod(persp_list, get, i);
      cp.perspective.push_back(obj_to_double(env, v));
      if (v) env->DeleteLocalRef(v);
    }
    env->DeleteLocalRef(list);
  }
  s->apply_crop(cp);
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeBrushStroke(
    JNIEnv* /*env*/, jobject /*thiz*/, jint view_id, jobject /*args*/) {
  auto s = get_session(view_id);
  if (s) s->request_render();
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeSpotHeal(
    JNIEnv* env, jobject /*thiz*/, jint view_id, jobject args) {
  heal::SpotParams p;
  if (args != nullptr) {
    jobject xo = map_get(env, args, "x");
    jobject yo = map_get(env, args, "y");
    jobject ro = map_get(env, args, "radius");
    p.x = (float)obj_to_double(env, xo);
    p.y = (float)obj_to_double(env, yo);
    p.radius = (float)obj_to_double(env, ro, 32.0);
    if (xo) env->DeleteLocalRef(xo);
    if (yo) env->DeleteLocalRef(yo);
    if (ro) env->DeleteLocalRef(ro);
  }
  heal::heal_spot(view_id, p);
  auto s = get_session(view_id);
  if (s) s->request_render();
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeLiquify(
    JNIEnv* env, jobject /*thiz*/, jint view_id, jobject args) {
  liquify::BrushOp op;
  if (args != nullptr) {
    jobject ko = map_get(env, args, "kind");
    jobject xo = map_get(env, args, "x");
    jobject yo = map_get(env, args, "y");
    jobject dxo = map_get(env, args, "dx");
    jobject dyo = map_get(env, args, "dy");
    jobject ro = map_get(env, args, "radius");
    jobject so = map_get(env, args, "strength");
    std::string k = obj_to_string(env, ko);
    if      (k == "pull")  op.kind = liquify::BrushKind::kPull;
    else if (k == "pinch") op.kind = liquify::BrushKind::kPinch;
    else if (k == "bloat") op.kind = liquify::BrushKind::kBloat;
    else if (k == "twirl") op.kind = liquify::BrushKind::kTwirl;
    else                   op.kind = liquify::BrushKind::kPush;
    op.x = (float)obj_to_double(env, xo);
    op.y = (float)obj_to_double(env, yo);
    op.dx = (float)obj_to_double(env, dxo);
    op.dy = (float)obj_to_double(env, dyo);
    op.radius = (float)obj_to_double(env, ro, 0.1);
    op.strength = (float)obj_to_double(env, so, 0.5);
    for (jobject o : {ko, xo, yo, dxo, dyo, ro, so}) {
      if (o) env->DeleteLocalRef(o);
    }
  }
  liquify::apply_brush(view_id, op);
  auto s = get_session(view_id);
  if (s) s->request_render();
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeBeautify(
    JNIEnv* /*env*/, jobject /*thiz*/, jint view_id, jobject /*args*/) {
  auto s = get_session(view_id);
  if (s) s->request_render();
}

JNIEXPORT jobject JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeReadPixels(
    JNIEnv* env, jobject /*thiz*/, jint view_id) {
  auto s = get_session(view_id);
  if (!s) return nullptr;
  int32_t w = 0, h = 0;
  std::vector<uint8_t> px = s->read_pixels(&w, &h);
  if (w <= 0 || h <= 0 || px.empty()) return nullptr;

  jclass bmpCls = env->FindClass("android/graphics/Bitmap");
  jclass cfgCls = env->FindClass("android/graphics/Bitmap$Config");
  jfieldID argb = env->GetStaticFieldID(cfgCls, "ARGB_8888",
                                        "Landroid/graphics/Bitmap$Config;");
  jobject cfg = env->GetStaticObjectField(cfgCls, argb);
  jmethodID create = env->GetStaticMethodID(
      bmpCls, "createBitmap",
      "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
  jobject bmp = env->CallStaticObjectMethod(bmpCls, create, w, h, cfg);
  void* pix = nullptr;
  if (AndroidBitmap_lockPixels(env, bmp, &pix) == 0) {
    std::memcpy(pix, px.data(), px.size());
    AndroidBitmap_unlockPixels(env, bmp);
  }
  env->DeleteLocalRef(bmpCls);
  env->DeleteLocalRef(cfgCls);
  env->DeleteLocalRef(cfg);
  return bmp;
}

JNIEXPORT jobject JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeRunFaceLandmarks(
    JNIEnv* env, jobject /*thiz*/, jint /*view_id*/, jstring /*src*/,
    jobject /*detector*/) {
  jclass list = env->FindClass("java/util/ArrayList");
  jmethodID ctor = env->GetMethodID(list, "<init>", "()V");
  jobject out = env->NewObject(list, ctor);
  env->DeleteLocalRef(list);
  return out;
}

JNIEXPORT jobject JNICALL
Java_com_loopit_minis_imgedit_ImageEditNative_nativeRunSelfieSegmentation(
    JNIEnv* env, jobject /*thiz*/, jint view_id, jstring /*src*/,
    jobject /*segmenter*/) {
  jclass hm = env->FindClass("java/util/HashMap");
  jmethodID ctor = env->GetMethodID(hm, "<init>", "()V");
  jobject map = env->NewObject(hm, ctor);
  jmethodID put = env->GetMethodID(hm, "put",
      "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
  jstring k1 = env->NewStringUTF("status");
  jstring v1 = env->NewStringUTF("pending_native_mask");
  env->CallObjectMethod(map, put, k1, v1);
  env->DeleteLocalRef(k1);
  env->DeleteLocalRef(v1);
  jstring k2 = env->NewStringUTF("viewId");
  jclass intCls = env->FindClass("java/lang/Integer");
  jmethodID intCtor = env->GetMethodID(intCls, "<init>", "(I)V");
  jobject vi = env->NewObject(intCls, intCtor, view_id);
  env->CallObjectMethod(map, put, k2, vi);
  env->DeleteLocalRef(k2);
  env->DeleteLocalRef(vi);
  env->DeleteLocalRef(intCls);
  env->DeleteLocalRef(hm);
  return map;
}

}  // extern "C"
