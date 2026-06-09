import 'package:flutter/material.dart';

/// Visual constants for the in-package image editor. Kept parallel to
/// `example/lib/editor/editor_config.dart` so the image editor reads as
/// the same product family as the video editor (dark surface + cyan
/// accent + rounded chips).
class MinisImageEditTheme {
  const MinisImageEditTheme._();

  static const Color accent = Color(0xFF00E5FF);
  static const Color bg = Color(0xFF000000);
  static const Color surface = Color(0xFF1A1A1A);
  static const Color surface2 = Color(0xFF2A2A2A);
  static const Color textSecondary = Color(0xFFAAAAAA);
  static const Color divider = Color(0xFF333333);
  static const Color danger = Color(0xFFFF5252);

  static const double dockHeight = 92;
  static const double panelHeight = 240;
  static const double thumbSize = 64;
}

/// Aspect-ratio chips shown in the crop tool. The numerator/denominator
/// pair feeds the cropper geometry; `null` means free-form.
class MinisImageEditAspect {
  const MinisImageEditAspect({
    required this.label,
    required this.num,
    required this.den,
  });

  final String label;
  final double? num;
  final double? den;

  double? get ratio {
    final n = num;
    final d = den;
    if (n == null || d == null || d == 0) return null;
    return n / d;
  }

  static const free = MinisImageEditAspect(label: 'Free', num: null, den: null);

  static const presets = <MinisImageEditAspect>[
    free,
    MinisImageEditAspect(label: '1:1', num: 1, den: 1),
    MinisImageEditAspect(label: '4:5', num: 4, den: 5),
    MinisImageEditAspect(label: '9:16', num: 9, den: 16),
    MinisImageEditAspect(label: '16:9', num: 16, den: 9),
    MinisImageEditAspect(label: '3:4', num: 3, den: 4),
    MinisImageEditAspect(label: '4:3', num: 4, den: 3),
  ];
}

/// Built-in filter previews shown when the native `listFilters` channel
/// returns nothing (skeleton / dev builds). Each entry is rendered with
/// a Flutter `ColorFilter.matrix` so the thumb grid is always populated.
enum MinisImageEditFilter {
  none,
  bw,
  sepia,
  warm,
  cool,
  vivid,
  fade,
  drama,
  mono,
  vintage,
}

extension MinisImageEditFilterMeta on MinisImageEditFilter {
  String get label {
    switch (this) {
      case MinisImageEditFilter.none:
        return 'Original';
      case MinisImageEditFilter.bw:
        return 'B&W';
      case MinisImageEditFilter.sepia:
        return 'Sepia';
      case MinisImageEditFilter.warm:
        return 'Warm';
      case MinisImageEditFilter.cool:
        return 'Cool';
      case MinisImageEditFilter.vivid:
        return 'Vivid';
      case MinisImageEditFilter.fade:
        return 'Fade';
      case MinisImageEditFilter.drama:
        return 'Drama';
      case MinisImageEditFilter.mono:
        return 'Mono';
      case MinisImageEditFilter.vintage:
        return 'Vintage';
    }
  }

  /// Wire-side identifier sent in `applyFilter(lutPath, intensity)`. The
  /// native pipeline can ignore it or load a matching `.cube` from
  /// `lib/assets/luts/<id>.cube` — Flutter side falls back to the matrix
  /// in `image_edit_filters.dart` for live thumbnail preview either way.
  String get id {
    switch (this) {
      case MinisImageEditFilter.none:
        return 'none';
      case MinisImageEditFilter.bw:
        return 'bw';
      case MinisImageEditFilter.sepia:
        return 'sepia';
      case MinisImageEditFilter.warm:
        return 'warm';
      case MinisImageEditFilter.cool:
        return 'cool';
      case MinisImageEditFilter.vivid:
        return 'vivid';
      case MinisImageEditFilter.fade:
        return 'fade';
      case MinisImageEditFilter.drama:
        return 'drama';
      case MinisImageEditFilter.mono:
        return 'mono';
      case MinisImageEditFilter.vintage:
        return 'vintage';
    }
  }
}

/// Adjust slider keys. Wire names match `applyAdjust(key,value)` in
/// `ImageEditEngine.kt` — `LayerStack` reads them through `currentAdjust`.
class MinisImageEditAdjustKey {
  const MinisImageEditAdjustKey._();

  static const String brightness = 'brightness';
  static const String contrast = 'contrast';
  static const String saturation = 'saturation';
  static const String exposure = 'exposure';
  static const String highlights = 'highlights';
  static const String shadows = 'shadows';
  static const String warmth = 'warmth';
  static const String tint = 'tint';
  static const String sharpness = 'sharpness';
  static const String vignette = 'vignette';

  /// Ordered (key, label, icon) for slider rendering.
  static const List<({String key, String label, IconData icon})> all = [
    (key: brightness, label: 'Brightness', icon: Icons.wb_sunny_outlined),
    (key: contrast, label: 'Contrast', icon: Icons.contrast),
    (key: saturation, label: 'Saturation', icon: Icons.invert_colors),
    (key: exposure, label: 'Exposure', icon: Icons.exposure),
    (key: highlights, label: 'Highlights', icon: Icons.brightness_5_outlined),
    (key: shadows, label: 'Shadows', icon: Icons.brightness_3_outlined),
    (key: warmth, label: 'Warmth', icon: Icons.thermostat),
    (key: tint, label: 'Tint', icon: Icons.color_lens_outlined),
    (key: sharpness, label: 'Sharpness', icon: Icons.deblur),
    (key: vignette, label: 'Vignette', icon: Icons.vignette),
  ];
}
