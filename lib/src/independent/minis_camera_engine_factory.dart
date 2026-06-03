import 'package:flutter/foundation.dart';

import 'package:loopit_minis/src/independent/minis_camera_performance.dart';
import 'package:loopit_minis/src/independent/native_android_minis_camera_engine.dart';
import 'package:loopit_minis/src/minis_capture_ports.dart';

/// Builds and initializes the native Minis camera engine.
///
/// Call **only after** camera + mic permissions are granted (or [assumeGranted]).
/// The same [NativeAndroidMinisCameraEngine] class drives both Android (CameraX)
/// and iOS (AVCaptureSession) through the shared
/// `com.buzzit.social/minis_native_camera` MethodChannel; the legacy
/// `package:camera` fallback has been removed.
///
/// `useNativeAndroidCamera` is retained for source-compat with prior callers
/// but is now ignored — there is no Dart camera package to fall back to.
Future<MinisCameraEnginePort> createMinisEngineAfterPermission({
  required MinisCameraPerformanceMode performanceMode,
  // ignore: avoid_positional_boolean_parameters
  required bool useNativeAndroidCamera,
  MinisResolutionPreset? resolutionPresetOverride,
}) async {
  if (kIsWeb) {
    throw UnsupportedError('Minis camera engine not supported on web');
  }
  final engine = NativeAndroidMinisCameraEngine(
    performanceMode: performanceMode,
    resolutionPresetOverride: resolutionPresetOverride,
  );
  await engine.initialize();
  return engine;
}
