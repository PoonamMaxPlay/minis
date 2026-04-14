import 'package:flutter/widgets.dart';

/// Whether [MinisIndependentCaptureScreen] should call permission APIs.
enum MinisCapturePermissionPolicy {
  /// Request camera + microphone (normal devices).
  request,

  /// Skip permission requests (tests / host-managed permissions).
  assumeGranted,
}

/// Pluggable camera backend for Minis capture without Retrytech.
///
/// Default implementation: [CameraPluginMinisEngine] (`package:camera`).
/// LoopIt may provide an adapter for another engine.
abstract class MinisCameraEnginePort {
  /// True after [initialize] completes successfully.
  bool get isInitialized;

  Future<void> initialize();

  Future<void> dispose();

  /// Live preview; safe to call before [isInitialized] (shows black / empty).
  Widget buildPreview(BuildContext context);

  /// Start video recording. [preferredOutputPath] is optional; the `camera`
  /// plugin usually picks a temp path. Implementors may honor it when possible.
  Future<void> startRecording({String? preferredOutputPath});

  /// Stop recording; return saved file path or null.
  Future<String?> stopRecording();

  /// Capture a still image to a temp path (idle only, not while recording).
  Future<String?> takePicture();

  /// Switch camera (e.g. front/back) when more than one is available.
  Future<void> switchCamera();

  /// Torch / lamp on the active camera (usually back only).
  Future<void> setTorchEnabled(bool enabled);

  /// Best-effort torch state after [setTorchEnabled].
  bool get isTorchOn;

  /// Recreate the camera with or without mic input (idle only, not while recording).
  Future<void> setRecordWithAudio(bool enabled);

  /// Device zoom (typically 1.0 … [getMaxZoomLevel]). No-op if unsupported.
  Future<double> getMinZoomLevel();

  Future<double> getMaxZoomLevel();

  Future<void> setZoomLevel(double zoom);
}
