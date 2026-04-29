import 'dart:io';

import 'package:camera/camera.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// User- or auto-selected camera cost / quality tradeoff for Minis preview + capture.
enum MinisCameraPerformanceMode {
  /// Infer from OS / device heuristics ([inferMinisCameraPerformanceMode]).
  auto,

  /// Smoothest preview: [ResolutionPreset.medium].
  performance,

  /// Balance: [ResolutionPreset.high].
  balanced,

  /// Matches previous Minis default: [ResolutionPreset.veryHigh].
  quality,
}

/// Maps a **non-auto** mode to a camera resolution preset.
ResolutionPreset resolutionPresetForMinisMode(MinisCameraPerformanceMode mode) {
  switch (mode) {
    case MinisCameraPerformanceMode.auto:
      throw ArgumentError.value(
        mode,
        'mode',
        'Use inferMinisCameraPerformanceMode() for auto',
      );
    case MinisCameraPerformanceMode.performance:
      return ResolutionPreset.medium;
    case MinisCameraPerformanceMode.balanced:
      return ResolutionPreset.high;
    case MinisCameraPerformanceMode.quality:
      return ResolutionPreset.veryHigh;
  }
}

/// Ordered rungs for stepping down when [CameraController.initialize] fails.
const List<ResolutionPreset> minisCameraResolutionRungs = <ResolutionPreset>[
  ResolutionPreset.veryHigh,
  ResolutionPreset.high,
  ResolutionPreset.medium,
  ResolutionPreset.low,
];

/// Returns presets to try, starting at [start] and continuing with lower rungs.
List<ResolutionPreset> minisPresetFallbackChain(ResolutionPreset start) {
  final i = minisCameraResolutionRungs.indexOf(start);
  if (i < 0) {
    return List<ResolutionPreset>.from(minisCameraResolutionRungs);
  }
  return minisCameraResolutionRungs.sublist(i);
}

/// Heuristic tier for [MinisCameraPerformanceMode.auto] (no user setting).
Future<MinisCameraPerformanceMode> inferMinisCameraPerformanceMode() async {
  if (kIsWeb) {
    return MinisCameraPerformanceMode.balanced;
  }
  try {
    final di = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await di.androidInfo;
      final sdk = a.version.sdkInt;
      // API 28 and below: typical low-RAM legacy stack; prefer lighter preview.
      if (sdk <= 28) {
        return MinisCameraPerformanceMode.performance;
      }
      if (sdk <= 31) {
        return MinisCameraPerformanceMode.balanced;
      }
      return MinisCameraPerformanceMode.quality;
    }
    if (Platform.isIOS) {
      final ios = await di.iosInfo;
      if (!ios.isPhysicalDevice) {
        return MinisCameraPerformanceMode.quality;
      }
      final m = ios.utsname.machine;
      final match = RegExp('iPhone([0-9]+),').firstMatch(m);
      if (match != null) {
        final gen = int.tryParse(match.group(1)!) ?? 999;
        // Model ordinal (Apple internal code) - rough proxy for chipset age.
        if (gen <= 11) {
          return MinisCameraPerformanceMode.performance;
        }
        if (gen <= 15) {
          return MinisCameraPerformanceMode.balanced;
        }
        return MinisCameraPerformanceMode.quality;
      }
      return MinisCameraPerformanceMode.balanced;
    }
  } catch (_) {
    // Ignore and fall through to balanced.
  }
  return MinisCameraPerformanceMode.balanced;
}