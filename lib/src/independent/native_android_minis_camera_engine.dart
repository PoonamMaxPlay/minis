import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:loopit_minis/src/independent/minis_camera_performance.dart';
import 'package:loopit_minis/src/minis_capture_ports.dart';

/// Android-only Minis camera via CameraX + embedded [AndroidView] preview.
///
/// Not available on non-Android platforms (do not construct outside [createMinisEngineAfterPermission]).
class NativeAndroidMinisCameraEngine implements MinisCameraEnginePort {
  NativeAndroidMinisCameraEngine({
    this.performanceMode = MinisCameraPerformanceMode.auto,
    this.resolutionPresetOverride,
  });

  static const MethodChannel _channel = MethodChannel(
    'com.buzzit.social/minis_native_camera',
  );

  final MinisCameraPerformanceMode performanceMode;
  final ResolutionPreset? resolutionPresetOverride;

  bool _initialized = false;
  bool _torchOn = false;
  bool _audioEnabled = true;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isTorchOn => _torchOn;

  Future<int> _qualityTier() async {
    if (resolutionPresetOverride != null) {
      switch (resolutionPresetOverride!) {
        case ResolutionPreset.low:
        case ResolutionPreset.medium:
          return 0;
        case ResolutionPreset.high:
          return 1;
        case ResolutionPreset.veryHigh:
        case ResolutionPreset.ultraHigh:
        case ResolutionPreset.max:
          return 2;
      }
    }

    if (performanceMode == MinisCameraPerformanceMode.auto) {
      final inferred = await inferMinisCameraPerformanceMode();
      return _tierFromMode(inferred);
    }
    return _tierFromMode(performanceMode);
  }

  int _tierFromMode(MinisCameraPerformanceMode m) {
    switch (m) {
      case MinisCameraPerformanceMode.auto:
        return 1;
      case MinisCameraPerformanceMode.performance:
        return 0;
      case MinisCameraPerformanceMode.balanced:
        return 1;
      case MinisCameraPerformanceMode.quality:
        return 2;
    }
  }

  @override
  Future<void> initialize() async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
      throw UnsupportedError(
        'NativeAndroidMinisCameraEngine is Android-only.',
      );
    }

    await _channel.invokeMethod<dynamic>('warmUp');

    var lastError = '';
    for (var attempt = 0; attempt < 8; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      try {
        final tier = await _qualityTier();
        await _channel.invokeMethod<dynamic>(
          'bind',
          <String, Object?>{
            'qualityTier': tier,
            'enableAudio': _audioEnabled,
          },
        );
        _initialized = true;
        return;
      } on PlatformException catch (e) {
        lastError = e.message ?? '$e';
        if (e.code == 'NO_PREVIEW' && attempt < 7) {
          await Future<void>.delayed(const Duration(milliseconds: 48));
          continue;
        }
        rethrow;
      }
    }
    throw StateError('Minis native camera bind failed: $lastError');
  }

  @override
  Future<void> dispose() async {
    _initialized = false;
    try {
      await _channel.invokeMethod<dynamic>('dispose');
    } catch (_) {}
  }

  @override
  Widget buildPreview(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          if (w <= 0) return const SizedBox.shrink();
          return Stack(
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: w,
                  height: w * (16 / 9),
                  child: const AndroidView(viewType: 'minis_native_camera'),
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
    await _channel.invokeMethod<dynamic>('startRecording', preferredOutputPath);
  }

  @override
  Future<String?> stopRecording() async {
    final p = await _channel.invokeMethod<String?>('stopRecording');
    return p;
  }

  @override
  Future<String?> takePicture() async {
    final p = await _channel.invokeMethod<String?>('takePicture');
    return p;
  }

  @override
  Future<void> switchCamera() async {
    await _channel.invokeMethod<dynamic>('switchCamera');
  }

  @override
  Future<void> setTorchEnabled(bool enabled) async {
    await _channel.invokeMethod<dynamic>('setTorchEnabled', enabled);
    _torchOn = enabled;
  }

  @override
  Future<void> setRecordWithAudio(bool enabled) async {
    if (_audioEnabled == enabled) return;
    _audioEnabled = enabled;
    await _channel.invokeMethod<dynamic>('setRecordWithAudio', enabled);
  }

  @override
  Future<double> getMinZoomLevel() async {
    final v = await _channel.invokeMethod<num>('getMinZoom');
    return v?.toDouble() ?? 1.0;
  }

  @override
  Future<double> getMaxZoomLevel() async {
    final v = await _channel.invokeMethod<num>('getMaxZoom');
    return v?.toDouble() ?? 1.0;
  }

  @override
  Future<void> setZoomLevel(double zoom) async {
    await _channel.invokeMethod<dynamic>('setZoomLevel', zoom);
  }
}