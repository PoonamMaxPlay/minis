#include "lut.h"

#include <GLES3/gl3.h>
#include <android/log.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#define LOG_TAG "MinisImgEditLut"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace minis::imgedit::lut {

namespace {

bool starts_with(const std::string& s, const char* tag) {
  size_t n = std::strlen(tag);
  return s.size() >= n && std::memcmp(s.data(), tag, n) == 0;
}

bool parse_lines(std::istringstream& in, ParsedLut* out) {
  std::string line;
  std::vector<float> values;
  int size = 0;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    while (!line.empty() && (line.back() == '\r' || line.back() == ' '))
      line.pop_back();
    if (line.empty() || line[0] == '#') continue;
    if (starts_with(line, "TITLE")) continue;
    if (starts_with(line, "LUT_3D_SIZE")) {
      size = std::atoi(line.c_str() + std::strlen("LUT_3D_SIZE "));
      continue;
    }
    if (starts_with(line, "DOMAIN_MIN")) {
      std::sscanf(line.c_str(), "DOMAIN_MIN %f %f %f",
                  &out->domain_min[0], &out->domain_min[1], &out->domain_min[2]);
      continue;
    }
    if (starts_with(line, "DOMAIN_MAX")) {
      std::sscanf(line.c_str(), "DOMAIN_MAX %f %f %f",
                  &out->domain_max[0], &out->domain_max[1], &out->domain_max[2]);
      continue;
    }
    float r, g, b;
    if (std::sscanf(line.c_str(), "%f %f %f", &r, &g, &b) == 3) {
      values.push_back(r);
      values.push_back(g);
      values.push_back(b);
    }
  }
  if (size <= 0 || (int)values.size() != size * size * size * 3) {
    LOGE("LUT parse mismatch: size=%d values=%zu", size, values.size());
    return false;
  }
  out->size = size;
  out->data = std::move(values);
  return true;
}

}  // namespace

bool parse_cube(const std::string& path, ParsedLut* out) {
  if (!out) return false;
  std::ifstream f(path);
  if (!f.is_open()) {
    LOGE("LUT open failed: %s", path.c_str());
    return false;
  }
  std::stringstream ss;
  ss << f.rdbuf();
  std::istringstream in(ss.str());
  return parse_lines(in, out);
}

bool parse_cube_buffer(const uint8_t* bytes, size_t len, ParsedLut* out) {
  if (!bytes || !out) return false;
  std::istringstream in(std::string(reinterpret_cast<const char*>(bytes), len));
  return parse_lines(in, out);
}

uint32_t upload_to_gl_texture3d(const ParsedLut& lut) {
  if (lut.size <= 0 || lut.data.empty()) return 0;
  GLuint tex = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_3D, tex);
  glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
  glTexImage3D(GL_TEXTURE_3D, 0, GL_RGB16F, lut.size, lut.size, lut.size, 0,
               GL_RGB, GL_FLOAT, lut.data.data());
  return tex;
}

}  // namespace minis::imgedit::lut
