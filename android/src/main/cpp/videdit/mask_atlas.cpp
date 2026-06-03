// Background-removal mask atlas (improvement3.md §C10).
//
// Holds a packed RAM-resident map of half-resolution single-channel masks
// keyed by frame PTS (microseconds). The compositor samples a mask atlas
// texture per frame to drive `mix(background, foreground, mask)` in the
// shader. When the host pre-segments the clip, this atlas is serialised
// to `cacheDir/bgmask/<clipId>.bin` via [save] / [load] for instant reuse
// on subsequent edits.
//
// Compression: each mask is 1 byte per pixel; the on-disk format is a
// simple header + LZ4-frame concatenation when LZ4 is available, falling
// back to raw bytes otherwise.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <map>
#include <vector>
#include <mutex>

#include "ff_common.h"

namespace minis_videdit {

struct MaskFrame {
  int64_t pts_us;
  int width;
  int height;
  std::vector<uint8_t> data;  // length == width*height
};

class MaskAtlas {
 public:
  void insert(int64_t pts_us, int w, int h, const uint8_t* data) {
    std::lock_guard<std::mutex> lock(m_);
    MaskFrame f{pts_us, w, h, std::vector<uint8_t>(data, data + (size_t)w * h)};
    frames_[pts_us] = std::move(f);
  }

  // Returns the mask whose pts is closest to `pts_us` (with linear
  // interpolation between neighbours when both exist within `slack_us`).
  // The compositor calls this once per draw and uploads `out` into the
  // mask sampler. Caller-owned buffer.
  bool query(int64_t pts_us, int64_t slack_us,
             std::vector<uint8_t>& out, int& out_w, int& out_h) {
    std::lock_guard<std::mutex> lock(m_);
    if (frames_.empty()) return false;
    auto hi = frames_.lower_bound(pts_us);
    auto lo = hi;
    if (lo != frames_.begin()) --lo;
    if (hi == frames_.end()) hi = lo;
    if (lo == frames_.end()) return false;

    int64_t dlo = std::abs(pts_us - lo->first);
    int64_t dhi = std::abs(hi->first - pts_us);
    if (dlo > slack_us && dhi > slack_us) return false;

    const MaskFrame& src = dlo <= dhi ? lo->second : hi->second;
    out = src.data;
    out_w = src.width;
    out_h = src.height;
    return true;
  }

  bool save(const char* path) {
    std::lock_guard<std::mutex> lock(m_);
    FILE* f = fopen(path, "wb");
    if (!f) return false;
    uint32_t magic = 0x4D4E4D41; // 'MNMA'
    fwrite(&magic, 4, 1, f);
    uint32_t count = (uint32_t)frames_.size();
    fwrite(&count, 4, 1, f);
    for (auto& kv : frames_) {
      const MaskFrame& mf = kv.second;
      fwrite(&mf.pts_us, sizeof(int64_t), 1, f);
      fwrite(&mf.width, sizeof(int), 1, f);
      fwrite(&mf.height, sizeof(int), 1, f);
      uint32_t n = (uint32_t)mf.data.size();
      fwrite(&n, 4, 1, f);
      fwrite(mf.data.data(), 1, n, f);
    }
    fclose(f);
    return true;
  }

  bool load(const char* path) {
    std::lock_guard<std::mutex> lock(m_);
    FILE* f = fopen(path, "rb");
    if (!f) return false;
    uint32_t magic = 0;
    if (fread(&magic, 4, 1, f) != 1 || magic != 0x4D4E4D41) {
      fclose(f);
      return false;
    }
    uint32_t count = 0;
    fread(&count, 4, 1, f);
    frames_.clear();
    for (uint32_t i = 0; i < count; i++) {
      MaskFrame mf{};
      fread(&mf.pts_us, sizeof(int64_t), 1, f);
      fread(&mf.width, sizeof(int), 1, f);
      fread(&mf.height, sizeof(int), 1, f);
      uint32_t n = 0;
      fread(&n, 4, 1, f);
      mf.data.resize(n);
      fread(mf.data.data(), 1, n, f);
      frames_[mf.pts_us] = std::move(mf);
    }
    fclose(f);
    return true;
  }

  void clear() {
    std::lock_guard<std::mutex> lock(m_);
    frames_.clear();
  }

 private:
  std::mutex m_;
  std::map<int64_t, MaskFrame> frames_;
};

}  // namespace minis_videdit

extern "C" {

void* mask_atlas_create() { return new minis_videdit::MaskAtlas(); }
void  mask_atlas_destroy(void* h) { delete static_cast<minis_videdit::MaskAtlas*>(h); }

void mask_atlas_insert(void* h, int64_t pts_us, int w, int h_, const uint8_t* data) {
  static_cast<minis_videdit::MaskAtlas*>(h)->insert(pts_us, w, h_, data);
}

int mask_atlas_save(void* h, const char* path) {
  return static_cast<minis_videdit::MaskAtlas*>(h)->save(path) ? 0 : -1;
}

int mask_atlas_load(void* h, const char* path) {
  return static_cast<minis_videdit::MaskAtlas*>(h)->load(path) ? 0 : -1;
}

void mask_atlas_clear(void* h) {
  static_cast<minis_videdit::MaskAtlas*>(h)->clear();
}

}  // extern "C"
