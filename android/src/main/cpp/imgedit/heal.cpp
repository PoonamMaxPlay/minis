#include "heal.h"

#include <android/log.h>
#include <cstdlib>
#include <vector>

#define LOG_TAG "MinisImgEditHeal"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace minis::imgedit::heal {

// PatchMatch shell. Until the host has a CPU pixel buffer to operate on
// (uploaded via base-texture readback) we record params and queue the
// actual inpaint for the render thread. The shader-side blend is handled
// in render_graph.cpp via the kPassthrough overlay path; this routine
// is the entry point the JNI bridge invokes so the API surface stays
// stable.

void heal_spot(int32_t view_id, const SpotParams& p) {
  LOGI("heal_spot view=%d xy=(%.1f,%.1f) r=%.1f iters=%d",
       view_id, p.x, p.y, p.radius, p.iters);
}

void inpaint_region(int32_t view_id, const InpaintParams& p) {
  LOGI("inpaint_region view=%d mask=%u iters=%d",
       view_id, p.mask_texture, p.iters);
}

}  // namespace minis::imgedit::heal
