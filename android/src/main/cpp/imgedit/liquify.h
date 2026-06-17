// Forward / inverse warp grid for liquify + face reshape.
//
// The warp field is a 32×32 displacement grid sampled bilinearly by the
// liquify fragment shader. Brush ops mutate the grid; face landmarks feed
// `auto_reshape` for one-shot face proportion tweaks.

#pragma once

#include <cstdint>
#include <vector>

namespace minis::imgedit::liquify {

enum class BrushKind {
  kPush,
  kPull,
  kPinch,
  kBloat,
  kTwirl,
};

struct BrushOp {
  BrushKind kind{BrushKind::kPush};
  float     x{0}, y{0};
  float     dx{0}, dy{0};
  float     radius{64};
  float     strength{0.5f};
};

struct Landmark {
  float x{0}, y{0};
  int   id{0};
};

void apply_brush(int32_t view_id, const BrushOp& op);
void auto_reshape(int32_t view_id, const std::vector<Landmark>& landmarks);
void reset(int32_t view_id);

}  // namespace minis::imgedit::liquify
