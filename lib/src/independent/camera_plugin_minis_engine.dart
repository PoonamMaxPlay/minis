import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:loopit_minis/src/independent/minis_camera_performance.dart';
import 'package:loopit_minis/src/minis_capture_ports.dart';

/// [MinisCameraEnginePort] backed by the official Flutter **`camera`** plugin
/// (no Retrytech). Suitable for Android / iOS; not for web.
class CameraPluginMinisEngine implements MinisCameraEnginePort {
  CameraPluginMinisEngine({
    this.performanceMode = MinisCameraPerformanceMode.auto,
    this.resolutionPresetOverride,
  });

  /// When set, forces this preset and skips [performanceMode] / auto inference.
  /// Intended for tests or host-provided tuning.
  final ResolutionPreset? resolutionPresetOverride;

  /// Auto (device heuristics) or a fixed quality band.
  final MinisCameraPerformanceMode performanceMode;

  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  bool _torchOn = false;
  bool _audioEnabled = true;

  /// First successful primary preset for this session (after auto-resolve).
  ResolutionPreset? _sessionPrimaryPreset;

  @override
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  @override
  bool get isTorchOn => _torchOn;

  Future<ResolutionPreset> _resolvePrimaryPreset() async {
    if (resolutionPresetOverride != null) {
      return resolutionPresetOverride!;
    }
    if (performanceMode == MinisCameraPerformanceMode.auto) {
      final inferred = await inferMinisCameraPerformanceMode();
      return resolutionPresetForMinisMode(inferred);
    }
    return resolutionPresetForMinisMode(performanceMode);
  }

  Future<void> _ensureSessionPrimaryPreset() async {
    _sessionPrimaryPreset ??= await _resolvePrimaryPreset();
  }

  @override
  Future<void> initialize() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) {
      throw StateError('No cameras available on this device.');
    }
    await _openCamera(_pickInitial());
  }

  CameraDescription _pickInitial() {
    for (final c in _cameras) {
      if (c.lensDirection == CameraLensDirection.back) return c;
    }
    return _cameras.first;
  }

  Future<void> _openCamera(CameraDescription description) async {
    await _openCameraWithAudio(description, _audioEnabled);
  }

  Future<void> _openCameraWithAudio(
    CameraDescription description,
    bool enableAudio,
  ) async {
    await _controller?.dispose();
    _controller = null;
    _torchOn = false;

    await _ensureSessionPrimaryPreset();
    final chain = minisPresetFallbackChain(_sessionPrimaryPreset!);

    Object? lastError;
    CameraController? created;
    for (final preset in chain) {
      try {
        created = CameraController(
          description,
          preset,
          enableAudio: enableAudio,
          imageFormatGroup: ImageFormatGroup.yuv420,
        );
        await created.initialize();
        // Lock capture orientation to portrait (matches Android behavior).
        await created.lockCaptureOrientation(DeviceOrientation.portraitUp);
        _controller = created;
        created = null;

        if (kDebugMode) {
          debugPrint(
            'MINIS_CAMERA: init ok preset=$preset mode=$performanceMode '
            'primary=$_sessionPrimaryPreset',
          );
        }
        return;
      } catch (e, st) {
        lastError = e;
        if (kDebugMode) {
          debugPrint('MINIS_CAMERA: init failed preset=$preset: $e\n$st');
        }
        await created?.dispose();
        created = null;
        _controller = null;
      }
    }

    throw StateError(
      'Camera initialization failed for all resolution rungs (from '
      '${chain.first}): $lastError',
    );
  }

  @override
  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
    _torchOn = false;
  }

  @override
  Widget buildPreview(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ar = c.value.aspectRatio;
          final w = constraints.maxWidth;
          return Stack(
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: w,
                  height: w * ar,
                  child: CameraPreview(c),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Future<void> startRecording({String? preferredOutputPath}) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isRecordingVideo) return;
    await c.startVideoRecording();
  }

  @override
  Future<String?> stopRecording() async {
    final c = _controller;
    if (c == null || !c.value.isRecordingVideo) return null;
    final xfile = await c.stopVideoRecording();
    return xfile.path;
  }

  @override
  Future<String?> takePicture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return null;
    if (c.value.isRecordingVideo) return null;
    final xfile = await c.takePicture();
    return xfile.path;
  }

  @override
  Future<void> switchCamera() async {
    if (_cameras.length < 2) return;
    final current = _controller?.description;
    final idx = current != null
        ? _cameras.indexWhere((d) => d.name == current.name)
        : -1;
    final nextIdx = idx < 0 ? 0 : (idx + 1) % _cameras.length;
    await _openCamera(_cameras[nextIdx]);
  }

  @override
  Future<void> setTorchEnabled(bool enabled) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (enabled) {
        await c.setFlashMode(FlashMode.torch);
      } else {
        await c.setFlashMode(FlashMode.off);
      }
      _torchOn = enabled;
    } catch (_) {
      _torchOn = false;
    }
  }

  @override
  Future<void> setRecordWithAudio(bool enabled) async {
    if (_audioEnabled == enabled) return;
    final c = _controller;
    if (c != null && c.value.isRecordingVideo) return;
    _audioEnabled = enabled;
    final desc = c?.description ?? _pickInitial();
    await setTorchEnabled(false);
    await _openCameraWithAudio(desc, _audioEnabled);
  }

  @override
  Future<double> getMinZoomLevel() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return 1.0;
    try {
      return await c.getMinZoomLevel();
    } catch (_) {
      return 1.0;
    }
  }

  @override
  Future<double> getMaxZoomLevel() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return 1.0;
    try {
      return await c.getMaxZoomLevel();
    } catch (_) {
      return 1.0;
    }
  }

  @override
  Future<void> setZoomLevel(double zoom) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setZoomLevel(zoom);
    } catch (_) {}
  }
}
