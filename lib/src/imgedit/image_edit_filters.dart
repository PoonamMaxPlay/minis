import 'package:flutter/material.dart';

import 'image_edit_theme.dart';

/// Live-preview `ColorMatrix` helpers used by the filter grid and the
/// stacked adjust overlay. Mirrors the math in
/// `example/lib/editor/editor_filters.dart` but operates over the
/// imgedit-specific `MinisImageEditFilter` enum + raw `adjust` map so
/// nothing in the package depends on the example app.
class MinisImageEditColorMatrix {
  const MinisImageEditColorMatrix._();

  static List<double> identity() => const [
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 1, 0, //
      ];

  static List<double> preset(MinisImageEditFilter p, double intensity) {
    final base = _presetMatrix(p);
    if (intensity >= 1.0) return base;
    final id = identity();
    final t = intensity.clamp(0.0, 1.0);
    return List<double>.generate(
      base.length,
      (i) => id[i] + (base[i] - id[i]) * t,
      growable: false,
    );
  }

  static List<double> _presetMatrix(MinisImageEditFilter p) {
    switch (p) {
      case MinisImageEditFilter.none:
        return identity();
      case MinisImageEditFilter.bw:
        return const [
          0.33, 0.59, 0.11, 0, 0,
          0.33, 0.59, 0.11, 0, 0,
          0.33, 0.59, 0.11, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case MinisImageEditFilter.sepia:
        return const [
          0.393, 0.769, 0.189, 0, 0,
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case MinisImageEditFilter.warm:
        return const [
          1.1, 0, 0, 0, 10,
          0, 1.0, 0, 0, 5,
          0, 0, 0.9, 0, -10,
          0, 0, 0, 1, 0,
        ];
      case MinisImageEditFilter.cool:
        return const [
          0.9, 0, 0, 0, -10,
          0, 1.0, 0, 0, 0,
          0, 0, 1.1, 0, 15,
          0, 0, 0, 1, 0,
        ];
      case MinisImageEditFilter.vivid:
        return _saturate(1.6);
      case MinisImageEditFilter.fade:
        return const [
          0.9, 0, 0, 0, 20,
          0, 0.9, 0, 0, 20,
          0, 0, 0.9, 0, 20,
          0, 0, 0, 1, 0,
        ];
      case MinisImageEditFilter.drama:
        return _contrast(1.4);
      case MinisImageEditFilter.mono:
        return _saturate(0.3);
      case MinisImageEditFilter.vintage:
        return const [
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

  /// Build the live adjust ColorMatrix from the slider map. Values are
  /// expected in [-1, 1]. Order/intensity tuned so the slider feels
  /// linear across its full range without saturating.
  static List<double> adjust(Map<String, double> a) {
    final brightness = (a[MinisImageEditAdjustKey.brightness] ?? 0) * 80;
    final exposure = (a[MinisImageEditAdjustKey.exposure] ?? 0) * 0.6;
    final c = (1.0 + (a[MinisImageEditAdjustKey.contrast] ?? 0) * 0.8) *
        (1.0 + exposure);
    final sat = 1.0 + (a[MinisImageEditAdjustKey.saturation] ?? 0) * 0.9;
    final hl = (a[MinisImageEditAdjustKey.highlights] ?? 0) * 25;
    final sh = (a[MinisImageEditAdjustKey.shadows] ?? 0) * 25;
    final warm = (a[MinisImageEditAdjustKey.warmth] ?? 0) * 30;
    final tintG = (a[MinisImageEditAdjustKey.tint] ?? 0) * 25;
    final tintRB = -(a[MinisImageEditAdjustKey.tint] ?? 0) * 15;
    final t = (1.0 - c) * 128;
    final inv = 1.0 - sat;
    final rs = 0.213 * inv;
    final gs = 0.715 * inv;
    final bs = 0.072 * inv;
    final tx = t + brightness + hl + sh;
    return [
      c * (rs + sat), c * gs, c * bs, 0, tx + warm + tintRB,
      c * rs, c * (gs + sat), c * bs, 0, tx + tintG,
      c * rs, c * gs, c * (bs + sat), 0, tx - warm + tintRB,
      0, 0, 0, 1, 0,
    ];
  }

  /// 4x5 matrix multiply (out = a * b). Same shape used in the video
  /// editor so the two pipelines compose identically.
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

/// Build the combined preview filter from a filter preset + intensity +
/// adjust map. Returned `ColorFilter` overlays the platform view so the
/// canvas reflects edits immediately, even before the native pipeline
/// echoes them back.
ColorFilter buildImageEditPreviewFilter({
  required MinisImageEditFilter filter,
  required double intensity,
  required Map<String, double> adjust,
}) {
  final filterMat = MinisImageEditColorMatrix.preset(filter, intensity);
  final adjustMat = MinisImageEditColorMatrix.adjust(adjust);
  final combined = MinisImageEditColorMatrix.combine(adjustMat, filterMat);
  return ColorFilter.matrix(combined);
}
