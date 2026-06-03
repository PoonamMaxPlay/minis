// Patch-match spot heal + content-aware inpaint.
//
// `heal_spot` works on a circular brush region using PatchMatch with
// random-init / propagation / random-search; `inpaint_region` accepts an
// arbitrary mask FBO for content-aware fill.

#pragma once

#include <cstdint>

namespace minis::imgedit::heal {

struct SpotParams {
  float x{0}, y{0};   // image-space center
  float radius{32};   // pixels
  int   iters{4};
};

void heal_spot(int32_t view_id, const SpotParams& p);

struct InpaintParams {
  uint32_t mask_texture{0};
  int      iters{4};
};

void inpaint_region(int32_t view_id, const InpaintParams& p);

}  // namespace minis::imgedit::heal
