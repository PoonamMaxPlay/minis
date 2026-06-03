import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:loopit_minis/src/independent/minis_camera_performance.dart';
import 'package:loopit_minis/src/minis_capture_ports.dart';

/// Cross-platform native Minis camera engine.
///
/// Backed by:
///   - Android: CameraX (PreviewView) in `MinisCameraXBridge` / `com.loopit.minis.camera.*`
///   - iOS: AVCaptureSession (UIView) in `ios/Classes/Camera/*`
///
/// Same `MethodChannel("com.buzzit.social/minis_native_camera")` is served by
/// both platforms. EventChannels for state, audio levels, metadata, analysis
/// share the same prefix.
class NativeAndroidMinisCameraEngine implements MinisCameraEnginePort {
  NativeAndroidMinisCameraEngine({
    this.performanceMode = MinisCameraPerformanceMode.auto,
    this.resolutionPresetOverride,
  });

  static const String _channelName = 'com.buzzit.social/minis_native_camera';
  static const String _platformViewId = 'minis_native_camera';

  static const MethodChannel _channel = MethodChannel(_channelName);
  static const EventChannel _stateChan =
      EventChannel('$_channelName/state');
  static const EventChannel _audioChan =
      EventChannel('$_channelName/audio_levels');
  static const EventChannel _metaChan =
      EventChannel('$_channelName/metadata');
  static const EventChannel _analysisChan =
      EventChannel('$_channelName/analysis');

  final MinisCameraPerformanceMode performanceMode;
  final MinisResolutionPreset? resolutionPresetOverride;

  bool _initialized = false;
  bool _torchOn = false;
  bool _audioEnabled = true;

  Stream<MinisEngineEvent>? _stateStream;
  Stream<MinisAudioLevels>? _audioLevelsStream;
  Stream<MinisFrameMetadata>? _metadataStream;
  Stream<List<Map<String, dynamic>>>? _analysisStream;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isTorchOn => _torchOn;

  Future<int> _qualityTier() async {
    if (resolutionPresetOverride != null) {
      return minisQualityTier(resolutionPresetOverride!);
    }
    final mode = performanceMode == MinisCameraPerformanceMode.auto
        ? await inferMinisCameraPerformanceMode()
        : performanceMode;
    return minisQualityTier(resolutionPresetForMinisMode(mode));
  }

  @override
  Future<void> initialize() async {
    if (kIsWeb) {
      throw UnsupportedError('NativeAndroidMinisCameraEngine not for web');
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
    if (!_initialized) return;
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
          final pv = defaultTargetPlatform == TargetPlatform.iOS
              ? const UiKitView(viewType: _platformViewId)
              : const AndroidView(viewType: _platformViewId);
          return Stack(
            fit: StackFit.expand,
            children: [
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: w,
                  height: w * (16 / 9),
                  child: pv,
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
    return _channel.invokeMethod<String?>('takePicture');
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

  // -------- Extended API --------

  @override
  Future<MinisCameraCapabilities> getCapabilities() async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>('getCapabilities');
      if (m == null) return const MinisCameraCapabilities();
      return MinisCameraCapabilities.fromMap(m);
    } catch (_) {
      return const MinisCameraCapabilities();
    }
  }

  @override
  Future<void> setFlashMode(MinisFlashMode mode) async {
    await _channel.invokeMethod<dynamic>(
      'setFlash',
      <String, Object?>{'mode': mode.name},
    );
    _torchOn = mode == MinisFlashMode.torch;
  }

  @override
  Future<void> setLens(MinisLensFacing lens) async {
    await _channel.invokeMethod<dynamic>(
      'setLens',
      <String, Object?>{'lensFacing': lens.name},
    );
  }

  @override
  Future<void> setExposureBias(double ev) async {
    await _channel.invokeMethod<dynamic>(
      'setExposure',
      <String, Object?>{'ev': ev},
    );
  }

  @override
  Future<void> setManual({
    int? iso,
    int? shutterNs,
    int? wbKelvin,
    double? lensPosition,
  }) async {
    await _channel.invokeMethod<dynamic>(
      'setManual',
      <String, Object?>{
        'iso': iso,
        'shutterNs': shutterNs,
        'wbKelvin': wbKelvin,
        'lensPos': lensPosition,
      },
    );
  }

  @override
  Future<void> tapToFocus({required double x, required double y}) async {
    await _channel.invokeMethod<dynamic>(
      'tapToFocus',
      <String, Object?>{'x': x, 'y': y},
    );
  }

  @override
  Future<bool> setResolution({
    required int width,
    required int height,
    required int fps,
  }) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'setResolution',
      <String, Object?>{'w': width, 'h': height, 'fps': fps},
    );
    return m?['accepted'] == true;
  }

  @override
  Future<bool> enableHdr(bool on) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'enableHdr',
      <String, Object?>{'on': on},
    );
    return m?['enabled'] == true;
  }

  @override
  Future<MinisSlowMoResult> enableSlowMo(int fps) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'enableSlowMo',
      <String, Object?>{'fps': fps},
    );
    if (m == null) return const MinisSlowMoResult(enabled: false, actualFps: 0);
    return MinisSlowMoResult(
      enabled: m['enabled'] == true,
      actualFps: (m['actualFps'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> enableTimeLapse({
    required Duration interval,
    required Duration duration,
  }) async {
    await _channel.invokeMethod<dynamic>(
      'enableTimeLapse',
      <String, Object?>{
        'intervalMs': interval.inMilliseconds,
        'durationMs': duration.inMilliseconds,
      },
    );
  }

  @override
  Future<void> startMultiCam(MinisMultiCamLayout layout) async {
    await _channel.invokeMethod<dynamic>(
      'startMultiCam',
      <String, Object?>{'layout': layout.name},
    );
  }

  @override
  Future<String?> stopMultiCam() async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>('stopMultiCam');
    return m?['path'] as String?;
  }

  @override
  Future<MinisPhotoResult?> takePhoto({bool raw = false, bool hdr = false}) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'takePhoto',
      <String, Object?>{'raw': raw, 'hdr': hdr},
    );
    if (m == null) return null;
    final path = m['path'] as String?;
    if (path == null) return null;
    final exifRaw = m['exif'];
    final exif = exifRaw is Map
        ? exifRaw.map((k, v) => MapEntry(k.toString(), v as dynamic))
        : <String, dynamic>{};
    return MinisPhotoResult(path: path, exif: exif);
  }

  @override
  Future<void> pauseRecording() async {
    await _channel.invokeMethod<dynamic>('pauseRecord');
  }

  @override
  Future<void> resumeRecording() async {
    await _channel.invokeMethod<dynamic>('resumeRecord');
  }

  @override
  Future<MinisRecordingResult?> stopRecordingResult() async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>('stopRecord');
    if (m == null) return null;
    final path = m['path'] as String?;
    if (path == null) return null;
    return MinisRecordingResult(
      path: path,
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      sizeBytes: (m['size'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<String?> finalizeClips(List<String> clipPaths) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'finalizeClips',
      <String, Object?>{'clipPaths': clipPaths},
    );
    return m?['mergedPath'] as String?;
  }

  @override
  Future<void> setMic({String? deviceId, double? gain}) async {
    await _channel.invokeMethod<dynamic>(
      'setMic',
      <String, Object?>{'deviceId': deviceId, 'gain': gain},
    );
  }

  @override
  Future<List<MinisMicDevice>> listMics() async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>('listMics');
      final raw = m?['mics'] as List?;
      if (raw == null) return const <MinisMicDevice>[];
      return raw
          .whereType<Map>()
          .map(MinisMicDevice.fromMap)
          .toList();
    } catch (_) {
      return const <MinisMicDevice>[];
    }
  }

  @override
  Future<MinisRecoveryInfo?> probeRecovery() async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>('probeRecovery');
      return MinisRecoveryInfo.fromMap(m);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> recoverAndFinalize({String? outPath}) async {
    final m = await _channel.invokeMapMethod<dynamic, dynamic>(
      'recoverAndFinalize',
      <String, Object?>{'outPath': outPath},
    );
    return m?['mergedPath'] as String?;
  }

  @override
  Future<void> discardRecovery() async {
    await _channel.invokeMethod<dynamic>('discardRecovery');
  }

  // -------- Event streams --------

  @override
  Stream<MinisEngineEvent> get stateStream {
    return _stateStream ??= _stateChan.receiveBroadcastStream().map((e) {
      if (e is Map) {
        final raw = e['state']?.toString() ?? 'idle';
        final state = MinisEngineState.values.firstWhere(
          (s) => s.name == raw,
          orElse: () => MinisEngineState.idle,
        );
        return MinisEngineEvent(
          state: state,
          code: e['code']?.toString(),
          message: e['message']?.toString(),
        );
      }
      return const MinisEngineEvent(state: MinisEngineState.idle);
    });
  }

  @override
  Stream<MinisAudioLevels> get audioLevelsStream {
    return _audioLevelsStream ??= _audioChan.receiveBroadcastStream().map((e) {
      if (e is Map) {
        return MinisAudioLevels(
          peak: (e['peak'] as num?)?.toDouble() ?? 0.0,
          rms: (e['rms'] as num?)?.toDouble() ?? 0.0,
        );
      }
      return const MinisAudioLevels(peak: 0, rms: 0);
    });
  }

  @override
  Stream<MinisFrameMetadata> get metadataStream {
    return _metadataStream ??= _metaChan.receiveBroadcastStream().map((e) {
      if (e is Map) {
        return MinisFrameMetadata(
          iso: (e['iso'] as num?)?.toInt(),
          shutterNs: (e['shutterNs'] as num?)?.toInt(),
          exposureBiasEv: (e['ev'] as num?)?.toDouble(),
          focusDistance: (e['focus'] as num?)?.toDouble(),
          wbKelvin: (e['wbKelvin'] as num?)?.toInt(),
          lensRatio: (e['lensRatio'] as num?)?.toDouble(),
        );
      }
      return const MinisFrameMetadata();
    });
  }

  @override
  Stream<List<Map<String, dynamic>>> get analysisStream {
    return _analysisStream ??= _analysisChan.receiveBroadcastStream().map((e) {
      if (e is List) {
        return e
            .whereType<Map>()
            .map((m) => m.map((k, v) => MapEntry(k.toString(), v as dynamic)))
            .toList();
      }
      return const <Map<String, dynamic>>[];
    });
  }
}
