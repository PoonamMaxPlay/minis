// Perspective transform + crop matrix.
//
// `crop_perspective` resolves a 3x3 homography from four source corners
// to the canvas rectangle and bakes it into a model matrix consumed by
// the base-layer vertex shader.

#pragma once

#include <array>

namespace minis::imgedit::crop {

using Mat3 = std::array<float, 9>;

struct PerspectiveCorners {
  float tl_x{0}, tl_y{0};
  float tr_x{1}, tr_y{0};
  float br_x{1}, br_y{1};
  float bl_x{0}, bl_y{1};
};

Mat3 solve_homography(const PerspectiveCorners& corners);
Mat3 crop_matrix(float x, float y, float w, float h, float rotation_deg);

}  // namespace minis::imgedit::crop
