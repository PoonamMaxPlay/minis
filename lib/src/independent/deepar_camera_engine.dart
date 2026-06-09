import 'dart:async';
import 'dart:io';

import 'package:deepar_flutter_plus/deepar_flutter_plus.dart';
import 'package:flutter/material.dart';

import 'package:loopit_minis/src/minis_capture_ports.dart';
import 'package:loopit_minis/src/independent/minis_deepar_catalog.dart';

/// DeepAR license keys — issued per app bundle id at developer.deepar.ai.
///
/// Pass via `--dart-define=DEEPAR_ANDROID_KEY=…` /
/// `--dart-define=DEEPAR_IOS_KEY=…` at build/run time. When BOTH are empty
/// (default), [DeepArCameraEngine] runs in **degraded** mode: the preview
/// shows the static `preview.png` thumbnail of the active filter and recording
/// / screenshot are disabled. This keeps the UI usable in CI and on engineer
/// laptops without leaked keys.
const String deepArAndroidKey =
    String.fromEnvironment('f2103308e73b7005caa550b78cf879dd5f6879e81c8f6976e5f0fe93d06bf49d5ad5f5a7341f6004', defaultValue: 'f2103308e73b7005caa550b78cf879dd5f6879e81c8f6976e5f0fe93d06bf49d5ad5f5a7341f6004');
const String deepArIosKey =
    String.fromEnvironment('DEEPAR_IOS_KEY', defaultValue: '');

/// Adapter that exposes [DeepArControllerPlus] as a [MinisCameraEnginePort] so
/// the existing capture screen (preview attach, start/stop record, take
/// picture) works unchanged while a DeepAR filter is active.
///
/// Lifecycle: the capture screen owns this engine — `initialize()` boots
/// [DeepArControllerPlus] and immediately applies [initialFilter]; further
/// filter changes go through [applyFilter]. `dispose()` calls `destroy()` on
/// the controller.
class DeepArCameraEngine extends MinisCameraEnginePort {
  DeepArCameraEngine({required this.initialFilter, this.resolution = Resolution.medium})
      : _activeFilter = initialFilter;

  final DeepArFilter initialFilter;
  final Resolution resolution;

  final DeepArControllerPlus _controller = DeepArControllerPlus();
  DeepArFilter _activeFilter;
  bool _initialized = false;
  bool _degraded = false;
  bool _recording = false;
  bool _torchOn = false;

  DeepArFilter get activeFilter => _activeFilter;

  /// True when license keys were empty — preview is static, recording disabled.
  bool get isDegraded => _degraded;

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final keysMissing = deepArAndroidKey.isEmpty && deepArIosKey.isEmpty;
    if (keysMissing) {
      _degraded = true;
      _initialized = true;
      return;
    }
    final result = await _controller.initialize(
      androidLicenseKey: deepArAndroidKey,
      iosLicenseKey: deepArIosKey,
      resolution: resolution,
    );
    if (!result.success) {
      _degraded = true;
      _initialized = true;
      return;
    }
    _initialized = true;
    await _controller.switchEffect(_activeFilter.assetPath);
  }

  /// Switches the running effect. No-op in degraded mode beyond updating the
  /// thumbnail rendered by [buildPreview].
  Future<void> applyFilter(DeepArFilter filter) async {
    _activeFilter = filter;
    if (_degraded) return;
    await _controller.switchEffect(filter.assetPath);
  }

  @override
  Widget buildPreview(BuildContext context) {
    if (_degraded) {
      return _DegradedPreview(filter: _activeFilter);
    }
    if (!_controller.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    return DeepArPreviewPlus(_controller);
  }

  @override
  Future<void> startRecording({String? preferredOutputPath}) async {
    if (_degraded) {
      throw StateError('DeepAR license keys missing — recording unavailable.');
    }
    await _controller.startVideoRecording();
    _recording = true;
  }

  @override
  Future<String?> stopRecording() async {
    if (!_recording) return null;
    _recording = false;
    if (_degraded) return null;
    final file = await _controller.stopVideoRecording();
    return file.path;
  }

  @override
  Future<String?> takePicture() async {
    if (_degraded) {
      throw StateError('DeepAR license keys missing — capture unavailable.');
    }
    final File f = await _controller.takeScreenshot();
    return f.path;
  }

  @override
  Future<void> switchCamera() async {
    if (_degraded) return;
    await _controller.flipCamera();
  }

  @override
  Future<void> setTorchEnabled(bool enabled) async {
    if (_degraded) return;
    if (enabled == _torchOn) return;
    final result = await _controller.toggleFlash();
    _torchOn = result;
  }

  @override
  bool get isTorchOn => _torchOn;

  @override
  Future<void> setRecordWithAudio(bool enabled) async {
    // DeepAR records the rendered preview; audio capture is on by default and
    // not toggleable through this plugin. Keep host-side toggling a no-op so
    // the mic chip stays consistent.
  }

  @override
  Future<double> getMinZoomLevel() async => 1.0;

  @override
  Future<double> getMaxZoomLevel() async => 1.0;

  @override
  Future<void> setZoomLevel(double zoom) async {
    // No DeepAR zoom API in deepar_flutter_plus 0.2.x. No-op; capture screen
    // simply clamps zoom to [1.0, 1.0] while in filter mode.
  }

  @override
  Future<void> dispose() async {
    if (_recording) {
      try {
        await _controller.stopVideoRecording();
      } catch (_) {/* swallow — best-effort */}
      _recording = false;
    }
    if (!_degraded) {
      try {
        await _controller.destroy();
      } catch (_) {/* swallow — best-effort */}
    }
    _initialized = false;
  }
}

class _DegradedPreview extends StatelessWidget {
  const _DegradedPreview({required this.filter});

  final DeepArFilter filter;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.auto_awesome,
                color: Color(0xFF7DD3FC), size: 72),
            const SizedBox(height: 16),
            Text(
              filter.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'DeepAR license keys missing.\n'
                'Pass --dart-define=DEEPAR_ANDROID_KEY=… '
                'and DEEPAR_IOS_KEY=… to render the live effect.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Colors.white70, fontSize: 12, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
