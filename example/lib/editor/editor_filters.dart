import 'package:flutter/material.dart';

import 'editor_state.dart';

class ColorFilters {
  static List<double> identity() => [
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
      ];

  static List<double> preset(FilterPreset p, double intensity) {
    final base = _presetMatrix(p);
    if (intensity >= 1.0) return base;
    final id = identity();
    final out = <double>[];
    for (var i = 0; i < base.length; i++) {
      out.add(id[i] + (base[i] - id[i]) * intensity);
    }
    return out;
  }

  static List<double> _presetMatrix(FilterPreset p) {
    switch (p) {
      case FilterPreset.none:
        return identity();
      case FilterPreset.bw:
        return [
          0.33, 0.59, 0.11, 0, 0,
          0.33, 0.59, 0.11, 0, 0,
          0.33, 0.59, 0.11, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case FilterPreset.sepia:
        return [
          0.393, 0.769, 0.189, 0, 0,
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case FilterPreset.warm:
        return [
          1.1, 0, 0, 0, 10,
          0, 1.0, 0, 0, 5,
          0, 0, 0.9, 0, -10,
          0, 0, 0, 1, 0,
        ];
      case FilterPreset.cool:
        return [
          0.9, 0, 0, 0, -10,
          0, 1.0, 0, 0, 0,
          0, 0, 1.1, 0, 15,
          0, 0, 0, 1, 0,
        ];
      case FilterPreset.vivid:
        return _saturate(1.6);
      case FilterPreset.fade:
        return [
          0.9, 0, 0, 0, 20,
          0, 0.9, 0, 0, 20,
          0, 0, 0.9, 0, 20,
          0, 0, 0, 1, 0,
        ];
      case FilterPreset.drama:
        return _contrast(1.4);
      case FilterPreset.mono:
        return _saturate(0.3);
      case FilterPreset.vintage:
        return [
          0.8, 0.4, 0.1, 0, 20,
          0.2, 0.8, 0.2, 0, 10,
          0.1, 0.3, 0.7, 0, 0,
          0, 0, 0, 1, 0,
        ];
    }
  }

  static List<double> _saturate(double s) {
    final inv = 1.0 - s;
    final r = 0.213 * inv;
    final g = 0.715 * inv;
    final b = 0.072 * inv;
    return [
      r + s, g, b, 0, 0,
      r, g + s, b, 0, 0,
      r, g, b + s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  static List<double> _contrast(double c) {
    final t = (1.0 - c) * 128;
    return [
      c, 0, 0, 0, t,
      0, c, 0, 0, t,
      0, 0, c, 0, t,
      0, 0, 0, 1, 0,
    ];
  }

  static List<double> adjust(EditorAdjust a) {
    final brightness = a.brightness * 80;
    final c = 1.0 + a.contrast * 0.8;
    final s = 1.0 + (a.saturation + a.vibrance * 0.6) * 0.9;
    final brill = a.brilliance * 30;
    final t = (1.0 - c) * 128;
    final inv = 1.0 - s;
    final rs = 0.213 * inv;
    final gs = 0.715 * inv;
    final bs = 0.072 * inv;
    // Temperature: warm (+) boosts R, cools B; tint: green/magenta.
    final tempR = a.temperature * 30;
    final tempB = -a.temperature * 30;
    final tintG = a.tint * 25;
    final tintRB = -a.tint * 15;
    return [
      c * (rs + s), c * gs, c * bs, 0, t + brightness + brill + tempR + tintRB,
      c * rs, c * (gs + s), c * bs, 0, t + brightness + brill + tintG,
      c * rs, c * gs, c * (bs + s), 0, t + brightness + brill + tempB + tintRB,
      0, 0, 0, 1, 0,
    ];
  }

  static List<double> combine(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 5; col++) {
        double sum = 0;
        for (var k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col == 4) sum += a[row * 5 + 4];
        out[row * 5 + col] = sum;
      }
    }
    return out;
  }
}

ColorFilter buildColorFilter(EditorState st) {
  final filterMat = ColorFilters.preset(st.filter, st.filterIntensity);
  final adjustMat = ColorFilters.adjust(st.adjust);
  final combined = ColorFilters.combine(adjustMat, filterMat);
  return ColorFilter.matrix(combined);
}
