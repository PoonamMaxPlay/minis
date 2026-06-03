import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:loopit_minis/src/sys/device_info.dart';

/// User- or auto-selected camera cost / quality tradeoff for Minis preview + capture.
enum MinisCameraPerformanceMode {
  /// Infer from OS / device heuristics ([inferMinisCameraPerformanceMode]).
  auto,

  /// Smoothest preview — lowest band.
  performance,

  /// Balance.
  balanced,

  /// Highest band.
  quality,
}

/// Resolution band (decoupled from `package:camera`).
///
/// Maps to native quality tiers:
///   low/medium → SD (Android Quality.SD / iOS 480p)
///   high       → HD  (720p)
///   veryHigh   → FHD (1080p)
///   ultraHigh  → UHD (2160p)
///   max        → SENSOR MAX
enum MinisResolutionPreset { low, medium, high, veryHigh, ultraHigh, max }

/// Maps a **non-auto** mode to a default resolution preset.
MinisResolutionPreset resolutionPresetForMinisMode(MinisCameraPerformanceMode mode) {
  switch (mode) {
    case MinisCameraPerformanceMode.auto:
      throw ArgumentError.value(
        mode,
        'mode',
        'Use inferMinisCameraPerformanceMode() for auto',
      );
    case MinisCameraPerformanceMode.performance:
      return MinisResolutionPreset.medium;
    case MinisCameraPerformanceMode.balanced:
      return MinisResolutionPreset.high;
    case MinisCameraPerformanceMode.quality:
      return MinisResolutionPreset.veryHigh;
  }
}

/// Ordered rungs for stepping down when bind fails.
const List<MinisResolutionPreset> minisCameraResolutionRungs = <MinisResolutionPreset>[
  MinisResolutionPreset.veryHigh,
  MinisResolutionPreset.high,
  MinisResolutionPreset.medium,
  MinisResolutionPreset.low,
];

/// Returns presets to try, starting at [start] and continuing with lower rungs.
List<MinisResolutionPreset> minisPresetFallbackChain(MinisResolutionPreset start) {
  final i = minisCameraResolutionRungs.indexOf(start);
  if (i < 0) {
    return List<MinisResolutionPreset>.from(minisCameraResolutionRungs);
  }
  return minisCameraResolutionRungs.sublist(i);
}

/// Native-side quality tier number (0=SD, 1=HD, 2=FHD, 3=UHD, 4=MAX).
int minisQualityTier(MinisResolutionPreset p) {
  switch (p) {
    case MinisResolutionPreset.low:
    case MinisResolutionPreset.medium:
      return 0;
    case MinisResolutionPreset.high:
      return 1;
    case MinisResolutionPreset.veryHigh:
      return 2;
    case MinisResolutionPreset.ultraHigh:
      return 3;
    case MinisResolutionPreset.max:
      return 4;
  }
}

/// Heuristic tier for [MinisCameraPerformanceMode.auto] (no user setting).
Future<MinisCameraPerformanceMode> inferMinisCameraPerformanceMode() async {
  if (kIsWeb) {
    return MinisCameraPerformanceMode.balanced;
  }
  try {
    final info = await NativeDeviceInfo.info();
    if (Platform.isAndroid) {
      final sdk = info.sdkInt;
      if (sdk <= 28) return MinisCameraPerformanceMode.performance;
      if (sdk <= 31) return MinisCameraPerformanceMode.balanced;
      return MinisCameraPerformanceMode.quality;
    }
    if (Platform.isIOS) {
      if (!info.isPhysicalDevice) {
        return MinisCameraPerformanceMode.quality;
      }
      final match = RegExp('iPhone([0-9]+),').firstMatch(info.machine);
      if (match != null) {
        final gen = int.tryParse(match.group(1)!) ?? 999;
        if (gen <= 11) return MinisCameraPerformanceMode.performance;
        if (gen <= 15) return MinisCameraPerformanceMode.balanced;
        return MinisCameraPerformanceMode.quality;
      }
      return MinisCameraPerformanceMode.balanced;
    }
  } catch (_) {
    // Fall through.
  }
  return MinisCameraPerformanceMode.balanced;
}
