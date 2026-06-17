/// Types for the native video editor engine (improvement3.md).
///
/// Phase 1 scaffold: Dart-side data classes mirror the native MethodChannel
/// contract `loopit/minis/videdit`. The native side is unimplemented in this
/// build, so most engine calls throw [VidEditUnsupportedError] and callers
/// fall back to safe defaults.
library;

import 'package:flutter/foundation.dart';

/// Thrown when a feature is not implemented in the current native build.
/// Callers should catch this and degrade gracefully (toast, return null, etc.).
class VidEditUnsupportedError implements Exception {
  const VidEditUnsupportedError(this.method, [this.detail]);

  final String method;
  final String? detail;

  @override
  String toString() {
    final d = detail == null ? '' : ': $detail';
    return 'VidEditUnsupportedError($method)$d';
  }
}

/// Thrown when the native engine reports a recoverable error.
class VidEditEngineError implements Exception {
  const VidEditEngineError(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'VidEditEngineError($code): $message';
}

/// Cancel marker — returned by export/render flows when user cancelled.
class VidEditCancelled implements Exception {
  const VidEditCancelled([this.taskId]);
  final String? taskId;
  @override
  String toString() => 'VidEditCancelled${taskId == null ? '' : '($taskId)'}';
}

/// Export presets enumerate the bitrate / codec combos described in
/// improvement3.md acceptance criteria.
enum VidEditExportPreset {
  reel1080(label: 'Reel 1080p H.264 8 Mbps'),
  story1080(label: 'Story 1080p H.264'),
  feed1080(label: 'Feed 1080×1080 H.264'),
  hd720(label: 'HD 720p'),
  uhd4k(label: '4K UHD'),
  hevc1080(label: '1080p HEVC'),
  prores(label: 'ProRes'),
  webmVp9(label: 'WebM VP9'),
  gif(label: 'GIF');

  const VidEditExportPreset({required this.label});
  final String label;
}

/// Codec selection on export. Used when [VidEditExportOptions.codec] is set.
enum VidEditCodec { h264, hevc, vp9, prores, gif }

/// Aspect / canvas presets.
enum VidEditAspect {
  square(1, 1),
  portrait916(9, 16),
  portrait45(4, 5),
  landscape169(16, 9),
  source(0, 0);

  const VidEditAspect(this.w, this.h);
  final int w;
  final int h;
}

@immutable
class VidEditExportOptions {
  const VidEditExportOptions({
    this.codec,
    this.targetBytes,
    this.twoPass = false,
    this.losslessCutIfPossible = true,
    this.audioBitrate = 128000,
    this.maxResolution,
    this.hardwareAcceleration = true,
  });

  final VidEditCodec? codec;
  final int? targetBytes;
  final bool twoPass;
  final bool losslessCutIfPossible;
  final int audioBitrate;
  final ({int w, int h})? maxResolution;
  final bool hardwareAcceleration;

  Map<String, Object?> toMap() => {
        if (codec != null) 'codec': codec!.name,
        if (targetBytes != null) 'targetBytes': targetBytes,
        'twoPass': twoPass,
        'losslessCutIfPossible': losslessCutIfPossible,
        'audioBitrate': audioBitrate,
        if (maxResolution != null)
          'maxResolution': {'w': maxResolution!.w, 'h': maxResolution!.h},
        'hardwareAcceleration': hardwareAcceleration,
      };
}

/// Minimal probe result returned by [MinisVidEdit.probe].
@immutable
class VidEditMetadata {
  const VidEditMetadata({
    required this.durationMs,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.frameRate,
    this.bitrate,
    this.hasAudio,
    this.fileSizeBytes,
    this.codec,
    this.fastStart,
  });

  final int durationMs;
  final int width;
  final int height;
  final int rotation;
  final double? frameRate;
  final int? bitrate;
  final bool? hasAudio;
  final int? fileSizeBytes;
  final String? codec;
  final bool? fastStart;

  factory VidEditMetadata.fromMap(Map<Object?, Object?> m) {
    int? _i(String k) => (m[k] as num?)?.toInt();
    double? _d(String k) => (m[k] as num?)?.toDouble();
    return VidEditMetadata(
      durationMs: _i('durationMs') ?? 0,
      width: _i('width') ?? 0,
      height: _i('height') ?? 0,
      rotation: _i('rotation') ?? 0,
      frameRate: _d('frameRate'),
      bitrate: _i('bitrate'),
      hasAudio: m['hasAudio'] as bool?,
      fileSizeBytes: _i('fileSizeBytes'),
      codec: m['codec'] as String?,
      fastStart: m['fastStart'] as bool?,
    );
  }
}

/// Native engine capabilities surfaced from `getCapabilities`.
@immutable
class VidEditCapabilities {
  const VidEditCapabilities({
    required this.engineAvailable,
    required this.ffmpegBuild,
    required this.codecs,
    required this.hwEnc,
    required this.hwDec,
    required this.maxResolution,
  });

  final bool engineAvailable;
  final String ffmpegBuild;
  final List<String> codecs;
  final List<String> hwEnc;
  final List<String> hwDec;
  final ({int w, int h})? maxResolution;

  static const unavailable = VidEditCapabilities(
    engineAvailable: false,
    ffmpegBuild: 'unbuilt',
    codecs: [],
    hwEnc: [],
    hwDec: [],
    maxResolution: null,
  );

  factory VidEditCapabilities.fromMap(Map<Object?, Object?> m) {
    final res = m['maxResolution'];
    ({int w, int h})? parsedRes;
    if (res is Map) {
      parsedRes = (
        w: (res['w'] as num?)?.toInt() ?? 0,
        h: (res['h'] as num?)?.toInt() ?? 0,
      );
    }
    return VidEditCapabilities(
      engineAvailable: (m['engineAvailable'] as bool?) ?? false,
      ffmpegBuild: (m['ffmpegBuild'] as String?) ?? 'unknown',
      codecs: List<String>.from((m['codecs'] as List?) ?? const []),
      hwEnc: List<String>.from((m['hwEnc'] as List?) ?? const []),
      hwDec: List<String>.from((m['hwDec'] as List?) ?? const []),
      maxResolution: parsedRes,
    );
  }
}

/// Volume envelope point used by audio tracks / master bus.
@immutable
class VidEditVolumePoint {
  const VidEditVolumePoint({required this.atMs, required this.gain});
  final int atMs;
  final double gain;

  Map<String, Object?> toMap() => {'atMs': atMs, 'gain': gain};
}

/// Transform applied to a clip (translate, scale, rotate, mirror).
@immutable
class VidEditTransform {
  const VidEditTransform({
    this.tx = 0,
    this.ty = 0,
    this.scaleX = 1,
    this.scaleY = 1,
    this.rotationDeg = 0,
    this.mirror = false,
    this.flip = false,
  });

  final double tx;
  final double ty;
  final double scaleX;
  final double scaleY;
  final double rotationDeg;
  final bool mirror;
  final bool flip;

  Map<String, Object?> toMap() => {
        'tx': tx,
        'ty': ty,
        'scaleX': scaleX,
        'scaleY': scaleY,
        'rotationDeg': rotationDeg,
        'mirror': mirror,
        'flip': flip,
      };
}

/// Single video / audio / overlay clip on the timeline.
@immutable
class VidEditClip {
  const VidEditClip({
    required this.id,
    required this.path,
    required this.trackIndex,
    required this.inMs,
    required this.outMs,
    required this.positionMs,
    this.transform,
    this.speed = 1.0,
    this.keepPitch = true,
    this.volume = 1.0,
    this.lutPath,
    this.lutIntensity = 1.0,
  });

  final String id;
  final String path;
  final int trackIndex;
  final int inMs;
  final int outMs;
  final int positionMs;
  final VidEditTransform? transform;
  final double speed;
  final bool keepPitch;
  final double volume;
  final String? lutPath;
  final double lutIntensity;

  Map<String, Object?> toMap() => {
        'id': id,
        'path': path,
        'trackIndex': trackIndex,
        'inMs': inMs,
        'outMs': outMs,
        'positionMs': positionMs,
        if (transform != null) 'transform': transform!.toMap(),
        'speed': speed,
        'keepPitch': keepPitch,
        'volume': volume,
        if (lutPath != null) 'lutPath': lutPath,
        'lutIntensity': lutIntensity,
      };
}

/// Timeline graph — serialized into JSON for `loadTimeline`.
@immutable
class VidEditTimeline {
  const VidEditTimeline({
    required this.clips,
    this.aspect = VidEditAspect.portrait916,
    this.masterVolumeEnv = const [],
  });

  final List<VidEditClip> clips;
  final VidEditAspect aspect;
  final List<VidEditVolumePoint> masterVolumeEnv;

  Map<String, Object?> toMap() => {
        'clips': clips.map((c) => c.toMap()).toList(),
        'aspect': {'w': aspect.w, 'h': aspect.h},
        'masterVolumeEnv':
            masterVolumeEnv.map((p) => p.toMap()).toList(growable: false),
      };
}

/// Progress event tag — what kind of task is reporting.
enum VidEditTaskKind { export, caption, stabilize, denoise, repair, render }

/// Progress event from the EventChannel `loopit/minis/videdit/progress`.
@immutable
class VidEditProgress {
  const VidEditProgress({
    required this.taskId,
    required this.kind,
    required this.pct,
    this.fps,
    this.etaMs,
  });

  final String taskId;
  final VidEditTaskKind kind;
  final double pct;
  final double? fps;
  final int? etaMs;

  factory VidEditProgress.fromMap(Map<Object?, Object?> m) {
    final kindStr = m['kind'] as String? ?? 'export';
    final kind = VidEditTaskKind.values.firstWhere(
      (k) => k.name == kindStr,
      orElse: () => VidEditTaskKind.export,
    );
    return VidEditProgress(
      taskId: (m['taskId'] as String?) ?? '',
      kind: kind,
      pct: ((m['pct'] as num?) ?? 0).toDouble().clamp(0.0, 1.0),
      fps: (m['fps'] as num?)?.toDouble(),
      etaMs: (m['etaMs'] as num?)?.toInt(),
    );
  }
}

/// Playback / engine state event from the EventChannel
/// `loopit/minis/videdit/state`.
@immutable
class VidEditState {
  const VidEditState({
    required this.playing,
    required this.positionMs,
    this.error,
  });

  final bool playing;
  final int positionMs;
  final String? error;

  factory VidEditState.fromMap(Map<Object?, Object?> m) {
    return VidEditState(
      playing: (m['playing'] as bool?) ?? false,
      positionMs: ((m['positionMs'] as num?) ?? 0).toInt(),
      error: m['error'] as String?,
    );
  }
}
