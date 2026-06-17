// Adobe `.cube` LUT parser. Reads a 17/32/64-cube file, validates lattice
// size + domain, uploads to a `GL_TEXTURE_3D` with `GL_RGB16F` storage.
//
// API surface keeps the parser separable from the GL upload so unit tests
// can hit `parse_cube` with an in-memory buffer.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace minis::imgedit::lut {

struct ParsedLut {
  int32_t size{0};                // lattice edge (cube side length)
  std::vector<float> data;        // size^3 * 3 RGB samples in [0, 1]
  float domain_min[3] = {0, 0, 0};
  float domain_max[3] = {1, 1, 1};
};

bool parse_cube(const std::string& path, ParsedLut* out_lut);
bool parse_cube_buffer(const uint8_t* bytes,
                       size_t len,
                       ParsedLut* out_lut);

uint32_t upload_to_gl_texture3d(const ParsedLut& lut);

}  // namespace minis::imgedit::lut
