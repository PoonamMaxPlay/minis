#include "crop.h"

#include <cmath>
#include <cstring>

namespace minis::imgedit::crop {

namespace {

// Solve A x = b via Gaussian elimination (n up to 8).
bool gauss_solve(double A[8][9]) {
  const int n = 8;
  for (int i = 0; i < n; ++i) {
    int piv = i;
    double best = std::abs(A[i][i]);
    for (int r = i + 1; r < n; ++r) {
      if (std::abs(A[r][i]) > best) { best = std::abs(A[r][i]); piv = r; }
    }
    if (best < 1e-12) return false;
    if (piv != i) {
      for (int c = 0; c < n + 1; ++c) std::swap(A[i][c], A[piv][c]);
    }
    for (int r = i + 1; r < n; ++r) {
      double k = A[r][i] / A[i][i];
      for (int c = i; c < n + 1; ++c) A[r][c] -= k * A[i][c];
    }
  }
  for (int i = n - 1; i >= 0; --i) {
    double s = A[i][n];
    for (int c = i + 1; c < n; ++c) s -= A[i][c] * A[c][n];
    A[i][n] = s / A[i][i];
  }
  return true;
}

}  // namespace

// Maps unit square (0,0)-(1,1) to four corners. Returns 3x3 row-major.
Mat3 solve_homography(const PerspectiveCorners& c) {
  // Source: unit square. Destination: corners.
  // For each correspondence (sx,sy)->(dx,dy):
  //   dx = (h0*sx + h1*sy + h2) / (h6*sx + h7*sy + 1)
  //   dy = (h3*sx + h4*sy + h5) / (h6*sx + h7*sy + 1)
  // Rewrite as:
  //   h0*sx + h1*sy + h2 - h6*sx*dx - h7*sy*dx = dx
  //   h3*sx + h4*sy + h5 - h6*sx*dy - h7*sy*dy = dy
  const double src[4][2] = {{0,0},{1,0},{1,1},{0,1}};
  const double dst[4][2] = {
    {c.tl_x, c.tl_y},
    {c.tr_x, c.tr_y},
    {c.br_x, c.br_y},
    {c.bl_x, c.bl_y},
  };
  double A[8][9] = {};
  for (int i = 0; i < 4; ++i) {
    double sx = src[i][0], sy = src[i][1];
    double dx = dst[i][0], dy = dst[i][1];
    int rx = i * 2;
    int ry = rx + 1;
    A[rx][0] = sx; A[rx][1] = sy; A[rx][2] = 1;
    A[rx][6] = -sx * dx; A[rx][7] = -sy * dx;
    A[rx][8] = dx;
    A[ry][3] = sx; A[ry][4] = sy; A[ry][5] = 1;
    A[ry][6] = -sx * dy; A[ry][7] = -sy * dy;
    A[ry][8] = dy;
  }
  Mat3 m{1,0,0, 0,1,0, 0,0,1};
  if (!gauss_solve(A)) return m;
  m[0] = (float)A[0][8]; m[1] = (float)A[1][8]; m[2] = (float)A[2][8];
  m[3] = (float)A[3][8]; m[4] = (float)A[4][8]; m[5] = (float)A[5][8];
  m[6] = (float)A[6][8]; m[7] = (float)A[7][8]; m[8] = 1.0f;
  return m;
}

Mat3 crop_matrix(float x, float y, float w, float h, float rotation_deg) {
  // Translate to rect center, rotate, scale to rect size.
  if (w <= 0) w = 1.0f;
  if (h <= 0) h = 1.0f;
  float cx = x + w * 0.5f;
  float cy = y + h * 0.5f;
  float rad = rotation_deg * 3.14159265358979f / 180.0f;
  float c = std::cos(rad);
  float s = std::sin(rad);
  // Mat3 in row-major:
  // [ w*c  -w*s   cx ]
  // [ h*s   h*c   cy ]
  // [  0    0     1  ]
  Mat3 m{
    w * c, -w * s, cx,
    h * s,  h * c, cy,
    0.0f,   0.0f,  1.0f,
  };
  return m;
}

}  // namespace minis::imgedit::crop
