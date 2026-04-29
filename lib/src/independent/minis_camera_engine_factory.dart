import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'package:loopit_minis/src/independent/camera_plugin_minis_engine.dart';
import 'package:loopit_minis/src/independent/minis_camera_performance.dart';
import 'package:loopit_minis/src/independent/native_android_minis_camera_engine.dart';
import 'package:loopit_minis/src/minis_capture_ports.dart';

/// Builds and initializes a camera engine with optional Android CameraX.
///
/// Call **only after** camera + mic permissions are granted (or [assumeGranted]).
/// Falls back to [CameraPluginMinisEngine] when not Android, flag off, or init fails.
Future<MinisCameraEnginePort> createMinisEngineAfterPermission({
  required MinisCameraPerformanceMode performanceMode,
  required bool useNativeAndroidCamera,
  ResolutionPreset? resolutionPresetOverride,
}) async {
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      useNativeAndroidCamera) {
    try {
      final native = NativeAndroidMinisCameraEngine(
        performanceMode: performanceMode,
        resolutionPresetOverride: resolutionPresetOverride,
      );
      await native.initialize();
      return native;
    } catch (e, st) {
      debugPrint(
        'MINIS: native Android camera init failed, using plugin: $e\n$st',
      );
    }
  }

  final plugin = CameraPluginMinisEngine(
    performanceMode: performanceMode,
    resolutionPresetOverride: resolutionPresetOverride,
  );
  await plugin.initialize();
  return plugin;
}