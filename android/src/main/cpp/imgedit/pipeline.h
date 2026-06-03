// Minis image-edit render-graph executor.
//
// The pipeline is built once per session (viewId) and walks the layer
// stack into the bound FBO each render request. Layers map 1:1 to the
// Kotlin `LayerStack.Kind` enum and shader programs live under `shaders/`.
//
// JNI surface — symbols expected by `ImageEditNative.kt`:
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeInitSession
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeDisposeView
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeSurfaceCreated
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeSurfaceChanged
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeSurfaceDestroyed
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeRequestRender
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeApplyAdjust
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeApplyFilter
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeApplyCrop
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeBrushStroke
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeSpotHeal
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeLiquify
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeBeautify
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeReadPixels
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeRunFaceLandmarks
//   Java_com_loopit_minis_imgedit_ImageEditNative_nativeRunSelfieSegmentation
//
// Compile via host app's `CMakeLists.txt` — the plugin gradle does not
// force-build C++ to keep the camera-only build path clean.

#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace minis::imgedit {

struct Rect {
  float x{0}, y{0}, w{0}, h{0};
};

struct AdjustParams {
  std::string key;
  double value{0.0};
};

struct LutParams {
  std::string path;
  double intensity{1.0};
};

struct CropParams {
  Rect rect{};
  double rotation_deg{0.0};
  std::vector<double> perspective;
};

class Session {
 public:
  virtual ~Session() = default;
  virtual void surface_created(void* native_surface) = 0;
  virtual void surface_changed(int32_t w, int32_t h) = 0;
  virtual void surface_destroyed() = 0;
  virtual void request_render() = 0;
  virtual void apply_adjust(const AdjustParams& p) = 0;
  virtual void apply_filter(const LutParams& p) = 0;
  virtual void apply_crop(const CropParams& p) = 0;
  virtual std::vector<uint8_t> read_pixels(int32_t* out_w,
                                           int32_t* out_h) = 0;
};

std::shared_ptr<Session> create_session(int32_t view_id,
                                        const std::string& source_path,
                                        int32_t width,
                                        int32_t height);

std::shared_ptr<Session> get_session(int32_t view_id);
void destroy_session(int32_t view_id);

}  // namespace minis::imgedit
