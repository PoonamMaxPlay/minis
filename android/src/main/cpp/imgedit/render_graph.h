// Render-graph executor. Walks an ordered list of Pass objects, binding
// programs / textures / FBOs and issuing a single fullscreen triangle-strip
// draw per pass.

#pragma once

#include <GLES3/gl3.h>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace minis::imgedit {

struct AdjustUniforms {
  float exposure{0};
  float contrast{0};
  float saturation{1};
  float temperature{0};
  float tint{0};
  float sharpen{0};
  float clarity{0};
  float dehaze{0};
};

struct CropUniforms {
  float homography[9] = {1,0,0, 0,1,0, 0,0,1};
  bool  active{false};
};

struct LutUniforms {
  GLuint texture{0};
  int    size{0};
  float  intensity{0};
};

enum class PassKind {
  kPassthrough,
  kAdjust,
  kLut,
  kCrop,
  kDraw,
  kMask,
  kSticker,
  kText,
  kEmoji,
};

struct Pass {
  PassKind kind{PassKind::kPassthrough};
  GLuint input_tex{0};
  GLuint extra_tex{0};   // mask / sticker / text / lut tex
  float  opacity{1.0f};
  int    blend_mode{0};  // 0 normal, 1 multiply, 2 screen, 3 overlay
};

class RenderGraph {
 public:
  RenderGraph();
  ~RenderGraph();

  bool init_programs();
  void destroy();

  void set_adjust(const AdjustUniforms& u) { adjust_ = u; }
  void set_lut(const LutUniforms& u) { lut_ = u; }
  void set_crop(const CropUniforms& u) { crop_ = u; }

  // Allocates / re-allocates output texture + FBO sized w x h.
  bool resize(int32_t w, int32_t h);

  // Bind base RGBA8 texture as the pipeline input.
  void set_base_texture(GLuint tex) { base_tex_ = tex; }

  // Run all passes. Final composite ends up in `output_tex` and also into
  // the currently bound default framebuffer if `present` is true.
  void execute(const std::vector<Pass>& passes, bool present);

  GLuint output_texture() const { return output_tex_; }
  int32_t width() const { return width_; }
  int32_t height() const { return height_; }

 private:
  GLuint compile_program(const char* vs, const char* fs);
  void draw_quad(GLuint program);

  GLuint vao_{0};
  GLuint vbo_{0};

  GLuint prog_passthrough_{0};
  GLuint prog_adjust_{0};
  GLuint prog_lut_{0};
  GLuint prog_crop_{0};
  GLuint prog_overlay_{0};

  GLuint base_tex_{0};
  GLuint output_tex_{0};
  GLuint fbo_a_{0};
  GLuint fbo_b_{0};
  GLuint tex_a_{0};
  GLuint tex_b_{0};

  int32_t width_{0};
  int32_t height_{0};

  AdjustUniforms adjust_{};
  CropUniforms   crop_{};
  LutUniforms    lut_{};
};

}  // namespace minis::imgedit
