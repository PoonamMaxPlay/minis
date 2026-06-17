import 'package:flutter/widgets.dart';

/// Whether [MinisIndependentCaptureScreen] should call permission APIs.
enum MinisCapturePermissionPolicy {
  /// Request camera + microphone (normal devices).
  request,

  /// Skip permission requests (tests / host-managed permissions).
  assumeGranted,
}

/// Flash modes mirroring the native enum (decoupled from `package:camera`).
enum MinisFlashMode { off, on, auto, torch }

/// Lens facing (decoupled from `package:camera`).
enum MinisLensFacing { back, front, external }

/// Multi-cam PiP layouts honored by the native engine when [startMultiCam] is called.
enum MinisMultiCamLayout { topLeft, topRight, bottomLeft, bottomRight, sideBySide }

/// Engine-advertised capability bundle, surfaced from native `getCapabilities`.
class MinisCameraCapabilities {
  const MinisCameraCapabilities({
    this.hdr10 = false,
    this.raw = false,
    this.slowMoFps = const <int>[],
    this.multiCam = false,
    this.manualIso = false,
    this.manualShutter = false,
    this.manualWb = false,
    this.manualFocus = false,
    this.timeLapse = false,
    this.minIso,
    this.maxIso,
    this.minShutterNs,
    this.maxShutterNs,
    this.maxZoom = 1.0,
    this.minZoom = 1.0,
  });

  final bool hdr10;
  final bool raw;
  final List<int> slowMoFps;
  final bool multiCam;
  final bool manualIso;
  final bool manualShutter;
  final bool manualWb;
  final bool manualFocus;
  final bool timeLapse;
  final int? minIso;
  final int? maxIso;
  final int? minShutterNs;
  final int? maxShutterNs;
  final double maxZoom;
  final double minZoom;

  static MinisCameraCapabilities fromMap(Map<dynamic, dynamic> m) {
    final slow = (m['slowMoFps'] as List?)?.cast<num>().map((e) => e.toInt()).toList() ??
        const <int>[];
    return MinisCameraCapabilities(
      hdr10: m['hdr10'] == true,
      raw: m['raw'] == true,
      slowMoFps: slow,
      multiCam: m['multiCam'] == true,
      manualIso: m['manualIso'] == true,
      manualShutter: m['manualShutter'] == true,
      manualWb: m['manualWb'] == true,
      manualFocus: m['manualFocus'] == true,
      timeLapse: m['timeLapse'] == true,
      minIso: (m['minIso'] as num?)?.toInt(),
      maxIso: (m['maxIso'] as num?)?.toInt(),
      minShutterNs: (m['minShutterNs'] as num?)?.toInt(),
      maxShutterNs: (m['maxShutterNs'] as num?)?.toInt(),
      maxZoom: (m['maxZoom'] as num?)?.toDouble() ?? 1.0,
      minZoom: (m['minZoom'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// Slow-motion negotiation result from native.
class MinisSlowMoResult {
  const MinisSlowMoResult({required this.enabled, required this.actualFps});
  final bool enabled;
  final int actualFps;
}

/// Photo result (path + best-effort EXIF map).
class MinisPhotoResult {
  const MinisPhotoResult({required this.path, this.exif = const {}});
  final String path;
  final Map<String, dynamic> exif;
}

/// Result of [stopRecording] / clip finalize.
class MinisRecordingResult {
  const MinisRecordingResult({
    required this.path,
    required this.durationMs,
    required this.sizeBytes,
  });
  final String path;
  final int durationMs;
  final int sizeBytes;
}

/// Live camera metadata sample emitted on the metadata stream.
class MinisFrameMetadata {
  const MinisFrameMetadata({
    this.iso,
    this.shutterNs,
    this.exposureBiasEv,
    this.focusDistance,
    this.wbKelvin,
    this.lensRatio,
  });
  final int? iso;
  final int? shutterNs;
  final double? exposureBiasEv;
  final double? focusDistance;
  final int? wbKelvin;
  final double? lensRatio;
}

/// Description of a single mic input device returned from `listMics`.
class MinisMicDevice {
  const MinisMicDevice({
    required this.id,
    required this.label,
    this.type,
    this.isDefault = false,
  });
  final String id;
  final String label;
  final String? type;
  final bool isDefault;

  static MinisMicDevice fromMap(Map<dynamic, dynamic> m) => MinisMicDevice(
        id: m['id']?.toString() ?? '',
        label: m['label']?.toString() ?? '',
        type: m['type']?.toString(),
        isDefault: m['isDefault'] == true,
      );
}

/// Crash-recovery probe: unfinished segments discovered on warm-up.
class MinisRecoveryInfo {
  const MinisRecoveryInfo({required this.segmentPaths, required this.totalDurationMs});
  final List<String> segmentPaths;
  final int totalDurationMs;

  static MinisRecoveryInfo? fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) return null;
    final paths = (m['segmentPaths'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
    if (paths.isEmpty) return null;
    return MinisRecoveryInfo(
      segmentPaths: paths,
      totalDurationMs: (m['totalDurationMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Audio peak/RMS pair emitted per N ms during recording.
class MinisAudioLevels {
  const MinisAudioLevels({required this.peak, required this.rms});
  final double peak;
  final double rms;
}

/// Engine high-level state from the state EventChannel.
enum MinisEngineState { idle, preview, recording, paused, stopped, finalized, error }

class MinisEngineEvent {
  const MinisEngineEvent({required this.state, this.code, this.message});
  final MinisEngineState state;
  final String? code;
  final String? message;
}

/// Pluggable camera backend for Minis capture.
///
/// Legacy methods kept for source-compat with `minis_capture_screen.dart`.
/// New work should target the extended API (manual controls, HDR, slow-mo,
/// multi-cam, EventChannel streams). All extended methods default to no-op so
/// older host adapters compile unchanged.
abstract class MinisCameraEnginePort {
  bool get isInitialized;

  Future<void> initialize();

  Future<void> dispose();

  Widget buildPreview(BuildContext context);

  Future<void> startRecording({String? preferredOutputPath});

  Future<String?> stopRecording();

  Future<String?> takePicture();

  Future<void> switchCamera();

  Future<void> setTorchEnabled(bool enabled);

  bool get isTorchOn;

  Future<void> setRecordWithAudio(bool enabled);

  Future<double> getMinZoomLevel();

  Future<double> getMaxZoomLevel();

  Future<void> setZoomLevel(double zoom);

  // -------- Extended API (default no-op) --------

  Future<MinisCameraCapabilities> getCapabilities() async =>
      const MinisCameraCapabilities();

  Future<void> setFlashMode(MinisFlashMode mode) async {
    if (mode == MinisFlashMode.torch) {
      await setTorchEnabled(true);
    } else {
      await setTorchEnabled(false);
    }
  }

  Future<void> setLens(MinisLensFacing lens) async {}

  Future<void> setExposureBias(double ev) async {}

  Future<void> setManual({
    int? iso,
    int? shutterNs,
    int? wbKelvin,
    double? lensPosition,
  }) async {}

  Future<void> tapToFocus({required double x, required double y}) async {}

  Future<bool> setResolution({required int width, required int height, required int fps}) async =>
      false;

  Future<bool> enableHdr(bool on) async => false;

  Future<MinisSlowMoResult> enableSlowMo(int fps) async =>
      const MinisSlowMoResult(enabled: false, actualFps: 0);

  Future<void> enableTimeLapse({
    required Duration interval,
    required Duration duration,
  }) async {}

  Future<void> startMultiCam(MinisMultiCamLayout layout) async {}

  Future<String?> stopMultiCam() async => null;

  Future<MinisPhotoResult?> takePhoto({bool raw = false, bool hdr = false}) async {
    final p = await takePicture();
    if (p == null) return null;
    return MinisPhotoResult(path: p);
  }

  Future<void> pauseRecording() async {}

  Future<void> resumeRecording() async {}

  Future<MinisRecordingResult?> stopRecordingResult() async {
    final p = await stopRecording();
    if (p == null) return null;
    return MinisRecordingResult(path: p, durationMs: 0, sizeBytes: 0);
  }

  Future<String?> finalizeClips(List<String> clipPaths) async => null;

  Future<void> setMic({String? deviceId, double? gain}) async {}

  Future<List<MinisMicDevice>> listMics() async => const <MinisMicDevice>[];

  // -------- Crash recovery --------

  Future<MinisRecoveryInfo?> probeRecovery() async => null;

  Future<String?> recoverAndFinalize({String? outPath}) async => null;

  Future<void> discardRecovery() async {}

  // -------- Streams (default empty) --------

  Stream<MinisEngineEvent> get stateStream => const Stream<MinisEngineEvent>.empty();

  Stream<MinisAudioLevels> get audioLevelsStream =>
      const Stream<MinisAudioLevels>.empty();

  Stream<MinisFrameMetadata> get metadataStream =>
      const Stream<MinisFrameMetadata>.empty();

  Stream<List<Map<String, dynamic>>> get analysisStream =>
      const Stream<List<Map<String, dynamic>>>.empty();
}
