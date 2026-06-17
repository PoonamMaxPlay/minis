// camera_pipeline.cpp — Minis CameraX C++ JNI helper.
//
// Provides YUV (NV12/NV21/I420) → RGBA8888 conversion for ImageAnalysis frames
// when MLKit / Vision is not used. Linked against `libyuv` (vendored Google
// implementation) when available; falls back to a portable bilinear-free
// reference loop otherwise.

#include <jni.h>
#include <android/log.h>
#include <cstdint>
#include <cstring>
#include <cstdlib>

#define LOG_TAG "MinisCameraPipeline"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

#if __has_include(<libyuv.h>)
#include <libyuv.h>
#define MINIS_HAS_LIBYUV 1
#else
#define MINIS_HAS_LIBYUV 0
#endif

namespace {

inline uint8_t clamp_u8(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return static_cast<uint8_t>(v);
}

// Reference NV21 → RGBA (BT.601). Slow but correct; used only when libyuv is missing.
void nv21_to_rgba_ref(const uint8_t* y_plane, int y_stride,
                      const uint8_t* vu_plane, int vu_stride,
                      uint8_t* dst, int dst_stride,
                      int width, int height) {
    for (int row = 0; row < height; ++row) {
        const uint8_t* y_row = y_plane + row * y_stride;
        const uint8_t* vu_row = vu_plane + (row / 2) * vu_stride;
        uint8_t* d_row = dst + row * dst_stride;
        for (int col = 0; col < width; ++col) {
            int y = y_row[col];
            int v = vu_row[(col / 2) * 2];
            int u = vu_row[(col / 2) * 2 + 1];
            int c = y - 16;
            int d = u - 128;
            int e = v - 128;
            int r = (298 * c           + 409 * e + 128) >> 8;
            int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
            int b = (298 * c + 516 * d           + 128) >> 8;
            d_row[col * 4 + 0] = clamp_u8(r);
            d_row[col * 4 + 1] = clamp_u8(g);
            d_row[col * 4 + 2] = clamp_u8(b);
            d_row[col * 4 + 3] = 255;
        }
    }
}

} // namespace

extern "C" {

JNIEXPORT void JNICALL
Java_com_loopit_minis_camera_NativePipeline_nv21ToRgba(
        JNIEnv* env, jclass /*cls*/,
        jobject y_buf, jint y_stride,
        jobject vu_buf, jint vu_stride,
        jobject dst_buf, jint dst_stride,
        jint width, jint height) {
    auto* y = static_cast<uint8_t*>(env->GetDirectBufferAddress(y_buf));
    auto* vu = static_cast<uint8_t*>(env->GetDirectBufferAddress(vu_buf));
    auto* dst = static_cast<uint8_t*>(env->GetDirectBufferAddress(dst_buf));
    if (!y || !vu || !dst) {
        LOGW("nv21ToRgba: null direct buffer");
        return;
    }
#if MINIS_HAS_LIBYUV
    libyuv::NV21ToABGR(y, y_stride, vu, vu_stride,
                       dst, dst_stride,
                       width, height);
#else
    nv21_to_rgba_ref(y, y_stride, vu, vu_stride, dst, dst_stride, width, height);
#endif
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_camera_NativePipeline_i420ToRgba(
        JNIEnv* env, jclass /*cls*/,
        jobject y_buf, jint y_stride,
        jobject u_buf, jint u_stride,
        jobject v_buf, jint v_stride,
        jobject dst_buf, jint dst_stride,
        jint width, jint height) {
    auto* y = static_cast<uint8_t*>(env->GetDirectBufferAddress(y_buf));
    auto* u = static_cast<uint8_t*>(env->GetDirectBufferAddress(u_buf));
    auto* v = static_cast<uint8_t*>(env->GetDirectBufferAddress(v_buf));
    auto* dst = static_cast<uint8_t*>(env->GetDirectBufferAddress(dst_buf));
    if (!y || !u || !v || !dst) {
        LOGW("i420ToRgba: null direct buffer");
        return;
    }
#if MINIS_HAS_LIBYUV
    libyuv::I420ToABGR(y, y_stride, u, u_stride, v, v_stride,
                       dst, dst_stride, width, height);
#else
    (void)u_stride; (void)v_stride;
    // Reference path: interleave UV → NV21 plane then call reference.
    auto* vu = static_cast<uint8_t*>(std::malloc(width * height / 2));
    if (!vu) return;
    for (int row = 0; row < height / 2; ++row) {
        for (int col = 0; col < width / 2; ++col) {
            vu[row * width + col * 2 + 0] = v[row * v_stride + col];
            vu[row * width + col * 2 + 1] = u[row * u_stride + col];
        }
    }
    nv21_to_rgba_ref(y, y_stride, vu, width, dst, dst_stride, width, height);
    std::free(vu);
#endif
}

} // extern "C"
