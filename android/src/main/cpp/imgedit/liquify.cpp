#include "liquify.h"

#include <android/log.h>
#include <cmath>
#include <mutex>
#include <unordered_map>
#include <vector>

#define LOG_TAG "MinisImgEditLiq"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace minis::imgedit::liquify {

namespace {

constexpr int kGridDim = 32;

struct Grid {
  std::vector<float> dx{};  // kGridDim * kGridDim
  std::vector<float> dy{};
  Grid() : dx(kGridDim * kGridDim, 0.0f), dy(kGridDim * kGridDim, 0.0f) {}
};

std::mutex g_mu;
std::unordered_map<int32_t, Grid> g_grids;

Grid& grid_for(int32_t view_id) {
  auto it = g_grids.find(view_id);
  if (it == g_grids.end()) {
    auto pr = g_grids.emplace(view_id, Grid{});
    return pr.first->second;
  }
  return it->second;
}

float gauss(float d, float r) {
  if (r <= 0.0f) return 0.0f;
  float x = d / r;
  return std::exp(-x * x * 4.0f);
}

}  // namespace

void apply_brush(int32_t view_id, const BrushOp& op) {
  std::lock_guard<std::mutex> lk(g_mu);
  Grid& g = grid_for(view_id);
  const float cx = op.x;
  const float cy = op.y;
  const float r  = op.radius;
  for (int gy = 0; gy < kGridDim; ++gy) {
    for (int gx = 0; gx < kGridDim; ++gx) {
      float u = (gx + 0.5f) / kGridDim;
      float v = (gy + 0.5f) / kGridDim;
      float dx = u - cx;
      float dy = v - cy;
      float d = std::sqrt(dx * dx + dy * dy);
      if (d > r) continue;
      float w = gauss(d, r) * op.strength;
      int idx = gy * kGridDim + gx;
      switch (op.kind) {
        case BrushKind::kPush:
          g.dx[idx] += op.dx * w;
          g.dy[idx] += op.dy * w;
          break;
        case BrushKind::kPull:
          g.dx[idx] -= op.dx * w;
          g.dy[idx] -= op.dy * w;
          break;
        case BrushKind::kPinch:
          g.dx[idx] -= dx * w;
          g.dy[idx] -= dy * w;
          break;
        case BrushKind::kBloat:
          g.dx[idx] += dx * w;
          g.dy[idx] += dy * w;
          break;
        case BrushKind::kTwirl: {
          float c = std::cos(w * 3.14159f);
          float s = std::sin(w * 3.14159f);
          float nx = dx * c - dy * s;
          float ny = dx * s + dy * c;
          g.dx[idx] += (nx - dx);
          g.dy[idx] += (ny - dy);
          break;
        }
      }
    }
  }
}

void auto_reshape(int32_t view_id, const std::vector<Landmark>& landmarks) {
  LOGI("auto_reshape view=%d landmarks=%zu", view_id, landmarks.size());
}

void reset(int32_t view_id) {
  std::lock_guard<std::mutex> lk(g_mu);
  g_grids.erase(view_id);
}

}  // namespace minis::imgedit::liquify
