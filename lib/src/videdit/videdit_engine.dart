/// Singleton facade over the native video editor engine described in
/// improvement3.md.
///
/// Talks to native code over MethodChannel `loopit/minis/videdit` and two
/// EventChannels (progress + state). The native implementation is not built
/// in this Phase 1 scaffold; calls that require native work throw
/// [VidEditUnsupportedError] so callers can degrade gracefully.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:loopit_minis/src/videdit/videdit_types.dart';

const String kVidEditMethodChannel = 'loopit/minis/videdit';
const String kVidEditProgressChannel = 'loopit/minis/videdit/progress';
const String kVidEditStateChannel = 'loopit/minis/videdit/state';
const String kVidEditPlatformViewType = 'loopit/minis/videdit/preview';

/// Singleton entry point. Use [MinisVidEdit.instance].
class MinisVidEdit {
  MinisVidEdit._();

  static final MinisVidEdit instance = MinisVidEdit._();

  static const MethodChannel _method = MethodChannel(kVidEditMethodChannel);
  static const EventChannel _progress = EventChannel(kVidEditProgressChannel);
  static const EventChannel _state = EventChannel(kVidEditStateChannel);

  VidEditCapabilities? _caps;
  Stream<VidEditProgress>? _progressStream;
  Stream<VidEditState>? _stateStream;

  /// Returns true when the native engine is built into the binary and ready.
  /// Cached after first probe.
  Future<bool> isAvailable() async {
    final caps = await getCapabilities();
    return caps.engineAvailable;
  }

  /// Synchronous best-effort check used by widgets that cannot await.
  /// Returns the last cached value; when the cache is cold this kicks off
  /// a background probe so the next call reflects reality without the
  /// caller needing to await.
  bool get isAvailableSync {
    if (_caps == null && !_probing && isPlatformEligible) {
      _probing = true;
      Future.microtask(() async {
        try { await getCapabilities(); } finally { _probing = false; }
      });
    }
    return _caps?.engineAvailable ?? false;
  }

  bool _probing = false;

  /// Platforms where we might eventually ship the native engine. iOS and
  /// Android only — desktop/web are out of scope per improvement3.md.
  bool get isPlatformEligible {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<VidEditCapabilities> getCapabilities() async {
    if (_caps != null) return _caps!;
    if (!isPlatformEligible) {
      _caps = VidEditCapabilities.unavailable;
      return _caps!;
    }
    try {
      final res =
          await _method.invokeMapMethod<Object?, Object?>('getCapabilities');
      _caps = res == null
          ? VidEditCapabilities.unavailable
          : VidEditCapabilities.fromMap(res);
    } on MissingPluginException {
      _caps = VidEditCapabilities.unavailable;
    } on PlatformException {
      _caps = VidEditCapabilities.unavailable;
    }
    return _caps!;
  }

  /// Reset cached capabilities. Tests only.
  @visibleForTesting
  void resetCapabilitiesCache() {
    _caps = null;
  }

  Stream<VidEditProgress> progressStream() {
    return _progressStream ??= _progress
        .receiveBroadcastStream()
        .map((dynamic e) => VidEditProgress.fromMap(e as Map<Object?, Object?>))
        .handleError((Object _) {});
  }

  Stream<VidEditState> stateStream() {
    return _stateStream ??= _state
        .receiveBroadcastStream()
        .map((dynamic e) => VidEditState.fromMap(e as Map<Object?, Object?>))
        .handleError((Object _) {});
  }

  /// Filters [progressStream] to a single task. Cheap: per-listener filter.
  Stream<VidEditProgress> progressFor(String taskId) {
    return progressStream().where((p) => p.taskId == taskId);
  }

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    if (!isPlatformEligible) {
      throw VidEditUnsupportedError(method, 'platform not eligible');
    }
    try {
      final res = await _method.invokeMethod<Object?>(method, args);
      return res as T;
    } on MissingPluginException {
      throw VidEditUnsupportedError(method, 'native plugin not registered');
    } on PlatformException catch (e) {
      if (e.code == 'unimplemented' || e.code == 'UNIMPLEMENTED') {
        throw VidEditUnsupportedError(method, e.message);
      }
      if (e.code == 'cancelled' || e.code == 'CANCELLED') {
        throw VidEditCancelled(e.message);
      }
      throw VidEditEngineError(e.code, e.message ?? '', e.details);
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // MethodChannel surface (see improvement3.md table).
  // ──────────────────────────────────────────────────────────────────

  Future<Map<String, Object?>> init() async {
    final res =
        await _invoke<Map<Object?, Object?>>('init', const <String, Object?>{});
    return res.cast<String, Object?>();
  }

  Future<int> loadTimeline(VidEditTimeline timeline) async {
    final res = await _invoke<Map<Object?, Object?>>(
      'loadTimeline',
      {'timeline': timeline.toMap()},
    );
    return (res['durationMs'] as num?)?.toInt() ?? 0;
  }

  Future<String> addClip({
    required String path,
    required int trackIndex,
    required int inMs,
    required int outMs,
    required int positionMs,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('addClip', {
      'path': path,
      'trackIndex': trackIndex,
      'inMs': inMs,
      'outMs': outMs,
      'position': positionMs,
    });
    return (res['clipId'] as String?) ?? '';
  }

  Future<({String leftId, String rightId})> splitClip({
    required String clipId,
    required int atMs,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('splitClip', {
      'clipId': clipId,
      'atMs': atMs,
    });
    return (
      leftId: (res['leftId'] as String?) ?? '',
      rightId: (res['rightId'] as String?) ?? '',
    );
  }

  Future<void> removeClip(String clipId) =>
      _invoke<void>('removeClip', {'clipId': clipId});

  Future<void> setClipTransform(String clipId, VidEditTransform t) =>
      _invoke<void>('setClipTransform', {
        'clipId': clipId,
        'transform': t.toMap(),
      });

  Future<void> setClipSpeed({
    required String clipId,
    required double factor,
    bool keepPitch = true,
  }) =>
      _invoke<void>('setClipSpeed', {
        'clipId': clipId,
        'factor': factor,
        'keepPitch': keepPitch,
      });

  Future<void> setClipFilter({
    required String clipId,
    required String lutPath,
    double intensity = 1.0,
  }) =>
      _invoke<void>('setClipFilter', {
        'clipId': clipId,
        'lutPath': lutPath,
        'intensity': intensity,
      });

  Future<String> addTransition({
    required String aId,
    required String bId,
    required String type,
    required int durMs,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('addTransition', {
      'aId': aId,
      'bId': bId,
      'type': type,
      'durMs': durMs,
    });
    return (res['transitionId'] as String?) ?? '';
  }

  Future<String> addText(Map<String, Object?> params) async {
    final res = await _invoke<Map<Object?, Object?>>(
      'addText',
      {'params': params},
    );
    return (res['overlayId'] as String?) ?? '';
  }

  Future<String> addSticker(Map<String, Object?> params) async {
    final res = await _invoke<Map<Object?, Object?>>(
      'addSticker',
      {'params': params},
    );
    return (res['overlayId'] as String?) ?? '';
  }

  Future<String> addAudioTrack({
    required String path,
    required int positionMs,
    List<VidEditVolumePoint> volumeEnv = const [],
    int? clipInMs,
    int? clipOutMs,
    double volume = 1.0,
    bool loop = false,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('addAudioTrack', {
      'path': path,
      'position': positionMs,
      'volumeEnv':
          volumeEnv.map((p) => p.toMap()).toList(growable: false),
      if (clipInMs != null) 'inMs': clipInMs,
      if (clipOutMs != null) 'outMs': clipOutMs,
      'volume': volume,
      'loop': loop,
    });
    return (res['trackId'] as String?) ?? '';
  }

  Future<void> setMasterVolumeEnv(List<VidEditVolumePoint> points) =>
      _invoke<void>('setMasterVolumeEnv', {
        'points': points.map((p) => p.toMap()).toList(growable: false),
      });

  Future<String> stabilize({
    required String clipId,
    String mode = 'medium',
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('stabilize', {
      'clipId': clipId,
      'mode': mode,
    });
    return (res['taskId'] as String?) ?? '';
  }

  Future<void> denoise({
    required String clipId,
    double strength = 0.5,
  }) =>
      _invoke<void>('denoise', {
        'clipId': clipId,
        'strength': strength,
      });

  Future<({String taskId, String subtitleId})> autoCaption({
    required String clipId,
    String lang = 'en-US',
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('autoCaption', {
      'clipId': clipId,
      'lang': lang,
    });
    return (
      taskId: (res['taskId'] as String?) ?? '',
      subtitleId: (res['subtitleId'] as String?) ?? '',
    );
  }

  Future<void> seek(int ms) => _invoke<void>('seek', {'ms': ms});
  Future<void> play() => _invoke<void>('play', const <String, Object?>{});
  Future<void> pause() => _invoke<void>('pause', const <String, Object?>{});

  /// Returns a list of JPEG/PNG byte buffers (one per requested thumb).
  Future<List<Uint8List>> thumbnailStrip({
    required String path,
    required int count,
    int width = 160,
    int height = 160,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('thumbnailStrip', {
      'path': path,
      'count': count,
      'w': width,
      'h': height,
    });
    final raw = res['thumbs'] as List?;
    if (raw == null) return const [];
    return raw
        .whereType<List<int>>()
        .map<Uint8List>(Uint8List.fromList)
        .toList(growable: false);
  }

  /// One-shot thumbnail at a given timestamp.
  Future<Uint8List?> thumbnailAt({
    required String path,
    required int atMs,
    int width = 240,
    int height = 240,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('thumbnailAt', {
      'path': path,
      'atMs': atMs,
      'w': width,
      'h': height,
    });
    final bytes = res['bytes'] as List<int>?;
    if (bytes == null || bytes.isEmpty) return null;
    return Uint8List.fromList(bytes);
  }

  /// Probes a media file. Used by metadata UI.
  Future<VidEditMetadata?> probe(String path) async {
    final res = await _invoke<Map<Object?, Object?>>('probe', {'path': path});
    return VidEditMetadata.fromMap(res);
  }

  /// One-clip trim to MP4. Frame-accurate when [reencode] is true; otherwise
  /// keyframe-aligned (lossless cut) when possible.
  Future<String> trim({
    required String inputPath,
    required String outputPath,
    required int startMs,
    required int endMs,
    bool reencode = true,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('trim', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'startMs': startMs,
      'endMs': endMs,
      'reencode': reencode,
    });
    return (res['outputPath'] as String?) ?? outputPath;
  }

  /// Repair / re-mux a file for safer downstream playback.
  Future<String?> repair({
    required String inputPath,
    required String outputPath,
    int targetHeight = 720,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('repair', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'targetHeight': targetHeight,
    });
    return res['outputPath'] as String?;
  }

  /// Concat multiple clips into one file.
  Future<String> concat({
    required List<String> inputPaths,
    required String outputPath,
    double speed = 1.0,
    bool keepAudio = true,
    String? musicPath,
    int musicStartMs = 0,
    int musicEndMs = 0,
    bool keepMusicTempo = false,
    String taskId = '',
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('concat', {
      'inputPaths': inputPaths,
      'outputPath': outputPath,
      'speed': speed,
      'keepAudio': keepAudio,
      if (musicPath != null) 'musicPath': musicPath,
      'musicStartMs': musicStartMs,
      'musicEndMs': musicEndMs,
      'keepMusicTempo': keepMusicTempo,
      'taskId': taskId,
    });
    return (res['outputPath'] as String?) ?? outputPath;
  }

  Future<String> export({
    required VidEditExportPreset preset,
    required String outPath,
    VidEditExportOptions options = const VidEditExportOptions(),
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('export', {
      'preset': preset.name,
      'outPath': outPath,
      'options': options.toMap(),
    });
    return (res['taskId'] as String?) ?? '';
  }

  Future<void> cancelTask(String taskId) =>
      _invoke<void>('cancelTask', {'taskId': taskId});

  /// Burns a `.srt` subtitle file into the video as an export pass. When
  /// `style` is provided it is forwarded to FFmpeg's `subtitles` filter as
  /// the `force_style` argument (e.g.
  /// `FontName=Inter,Fontsize=24,PrimaryColour=&Hffffff&`).
  Future<String> burnCaptions({
    required String inputPath,
    required String outputPath,
    required String srtPath,
    String? style,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('burnCaptions', {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'srtPath': srtPath,
      if (style != null) 'style': style,
    });
    return (res['outputPath'] as String?) ?? outputPath;
  }

  /// Mixes N audio sources through a filter string (typically produced by
  /// `ff_audio_graph_build_graph` on the native side) into a single AAC mp4.
  /// Use this when voiceover ducking against a separate music track is
  /// needed — the single-input audio path inside [export] only operates on
  /// the clip's own audio stream.
  Future<String> mixAudio({
    required List<String> audioInputs,
    required String filter,
    required String outputPath,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('mixAudio', {
      'audioInputs': audioInputs,
      'filter': filter,
      'outputPath': outputPath,
    });
    return (res['outputPath'] as String?) ?? outputPath;
  }

  /// Replaces the audio track of [videoPath] with [audioPath] via stream-copy
  /// remux. Output is an mp4 with `+faststart`.
  Future<String> replaceAudio({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('replaceAudio', {
      'videoPath': videoPath,
      'audioPath': audioPath,
      'outputPath': outputPath,
    });
    return (res['outputPath'] as String?) ?? outputPath;
  }

  /// Composites a new background behind the subject using a mask atlas
  /// produced by the on-device segmenter (`BgRemover` on each platform).
  /// `bgSpec` is either a hex `#RRGGBB` colour or a path to a still image.
  Future<String> composeBackground({
    required String inputPath,
    required String maskAtlasPath,
    required String outputPath,
    String bgSpec = '#000000',
  }) async {
    final res = await _invoke<Map<Object?, Object?>>('composeBackground', {
      'inputPath': inputPath,
      'maskAtlasPath': maskAtlasPath,
      'outputPath': outputPath,
      'bgSpec': bgSpec,
    });
    return (res['outputPath'] as String?) ?? outputPath;
  }
}
