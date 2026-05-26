import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import 'package:loopit_minis/src/debug/video_aspect_log.dart';
import 'package:loopit_minis/src/independent/minis_music_segment.dart';
import 'package:loopit_minis/src/minis_capture_host.dart';
import 'package:loopit_minis/src/minis_user_message.dart';
import 'package:loopit_minis/src/session_and_toast.dart';
import 'package:video_player/video_player.dart' as vp;

/// iOS: AVAssetExportSession cannot read files from tmp/ during composition,
/// and AVPlayer cannot play files from Library/Caches.
/// This helper copies any tmp/ clips to Documents and returns safe paths.
/// On Android this is a no-op — returns original paths unchanged.
Future<List<String>> _sanitizeClipPathsForIos(List<String> paths) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return paths;
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, 'loopit_minis_captures'));
  if (!await dir.exists()) await dir.create(recursive: true);

  final result = <String>[];
  for (final path in paths) {
    if (path.contains('/tmp/') || path.contains('/Caches/')) {
      try {
        final ext = p.extension(path);
        final dest = p.join(
          dir.path,
          'minis_safe_${DateTime.now().microsecondsSinceEpoch}$ext',
        );
        await File(path).copy(dest);
        result.add(dest);
        // Best-effort cleanup of source.
        try { await File(path).delete(); } catch (_) {}
      } catch (e) {
        dev.log('minis: clip copy failed for $path: $e', name: 'MinisMerge');
        result.add(path); // fallback to original
      }
    } else {
      result.add(path);
    }
  }
  return result;
}

/// On iOS, AVAssetExportSession writes to Caches (tmp), but AVPlayer
/// cannot play files from there (-12660). After export, copy to Documents.
Future<String> _copyToDocumentsIfIos(String cachePath) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return cachePath;
  try {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'loopit_minis_captures'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final ext = p.extension(cachePath);
    final dest = p.join(
      dir.path,
      'minis_reel_${DateTime.now().microsecondsSinceEpoch}$ext',
    );
    await File(cachePath).copy(dest);
    try { await File(cachePath).delete(); } catch (_) {}
    return dest;
  } catch (e) {
    dev.log('minis: cache→docs copy failed: $e', name: 'MinisMerge');
    return cachePath; // fallback
  }
}

/// Returns the working directory for intermediate two-pass artifacts. On iOS
/// we write directly to Documents to skip the tmp/Caches sanitize+copy dance.
Future<Directory> _intermediateWorkDir() async {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'loopit_minis_captures'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
  return getTemporaryDirectory();
}

/// Same platforms as [proVideoEditorRenderExportSupported] in hub (no web).
bool minisMulticlipMergeSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

bool _mergeCancelSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

/// Music-tempo preservation requires a second render pass: pro_video_editor
/// applies [playbackSpeed] to **every** track in the composition (iOS scales
/// each `AVMutableCompositionTrack` time range; Android shares the speed
/// audio processor with custom audio tracks in some pipeline paths). That
/// pitches music up/down. To keep music at native tempo we render the
/// speed-adjusted video first (without music), then mux music at speed 1.0
/// over the result.
bool _needsMusicTempoPass(double playbackSpeed, MinisMusicSegment? music) {
  if (playbackSpeed == 1.0) return false;
  final path = music?.path.trim();
  if (path == null || path.isEmpty) return false;
  return File(path).existsSync();
}

/// Probes merged file with video_player (debug) so logs match feed/reel [VideoAspectDiag].
void _logMergedVideoFileProbe(String outPath) {
  unawaited(() async {
    final c = vp.VideoPlayerController.file(File(outPath));
    try {
      await c.initialize();
      logMinisVideoAspectDiag('minis_merge_output', c.value, pathHint: outPath);
    } catch (e, st) {
      dev.log('minis merge file probe failed: $e',
          name: 'VideoAspectDiag', stackTrace: st);
    } finally {
      await c.dispose();
    }
  }());
}

VideoRenderData _buildSinglePassData({
  required String id,
  required List<String> safeClipPaths,
  required double playbackSpeed,
  required bool enableAudio,
  required List<VideoAudioTrack> audioTracks,
  required double? clipVolume,
}) {
  // Use the same quality path as hub export: plain [VideoRenderData] omits
  // [qualityConfig]/bitrate and the encoder can fall back to a much lower
  // output than the camera-captured clips.
  // Explicit 1:1 scale skips [VideoRenderData.toAsyncMap]'s metadata-driven
  // fit (getMetadata on first segment). That probe can throw METADATA_ERROR
  // / setDataSource failures for some temp or gallery paths while export
  // would still succeed with fixed scales + quality bitrate.
  return VideoRenderData.withQualityPreset(
    id: id,
    videoSegments: safeClipPaths
        .map(
          (path) => VideoSegment(
            video: EditorVideo.file(File(path)),
            volume: clipVolume,
          ),
        )
        .toList(),
    qualityPreset: VideoQualityPreset.p1080High,
    outputFormat: VideoOutputFormat.mp4,
    playbackSpeed: playbackSpeed,
    enableAudio: enableAudio,
    audioTracks: audioTracks,
    transform: const ExportTransform(scaleX: 1.0, scaleY: 1.0),
  );
}

/// Pass 1 of the music-tempo preservation flow: bake the speed change into
/// the video stream (and clip mic audio) with no music attached.
VideoRenderData _buildPassOneData({
  required String id,
  required List<String> safeClipPaths,
  required double playbackSpeed,
  required bool enableAudio,
}) {
  return _buildSinglePassData(
    id: id,
    safeClipPaths: safeClipPaths,
    playbackSpeed: playbackSpeed,
    enableAudio: enableAudio,
    audioTracks: const [],
    clipVolume: null,
  );
}

/// Pass 2: take the already-sped intermediate as the single segment, render
/// at speed 1.0 with music attached so the music plays at its native tempo.
/// Existing clip audio in the intermediate is ducked via [VideoSegment.volume].
VideoRenderData _buildPassTwoData({
  required String id,
  required String passOnePath,
  required bool enableAudio,
  required MinisMusicSegment music,
}) {
  final clipVolume = enableAudio ? 0.35 : 0.0;
  final track = VideoAudioTrack(
    path: music.path,
    volume: 1.0,
    loop: true,
    audioStartTime: Duration(milliseconds: music.startMs),
    audioEndTime: Duration(milliseconds: music.endMs),
  );
  return VideoRenderData.withQualityPreset(
    id: id,
    videoSegments: [
      VideoSegment(
        video: EditorVideo.file(File(passOnePath)),
        volume: clipVolume,
      ),
    ],
    qualityPreset: VideoQualityPreset.p1080High,
    outputFormat: VideoOutputFormat.mp4,
    playbackSpeed: 1.0,
    enableAudio: true,
    audioTracks: [track],
    transform: const ExportTransform(scaleX: 1.0, scaleY: 1.0),
  );
}

/// Mutable holder so the cancel button can target whichever pass is running.
class _ActiveTaskRef {
  String? id;
}

/// Bridges per-pass native progress streams into a single 0..1 stream for
/// the dialog / handoff overlay. Pass-1 occupies 0..0.5, pass-2 0.5..1.0;
/// single-pass renders forward raw 0..1 unchanged.
StreamSubscription<ProgressModel> _pipeProgress({
  required String taskId,
  required StreamController<double> sink,
  required double offset,
  required double scale,
}) {
  return ProVideoEditor.instance.progressStreamById(taskId).listen((snap) {
    if (sink.isClosed) return;
    final v = (offset + snap.progress * scale).clamp(0.0, 1.0);
    sink.add(v);
  });
}

/// Concatenate [clipPaths] with [playbackSpeed] and optional audio; shows progress.
///
/// When [backgroundMusic] is set and the file exists, it is mixed in as a
/// [VideoAudioTrack] (trimmed to [MinisMusicSegment.startMs]/[MinisMusicSegment.endMs]
/// when provided); clip audio is ducked via [VideoSegment.volume] when mixing.
///
/// Returns output path on success, or `null` on cancel / unsupported / error.
Future<String?> mergeMinisVideoClipsWithDialog({
  required BuildContext context,
  required List<String> clipPaths,
  required double playbackSpeed,
  required bool enableAudio,
  MinisMusicSegment? backgroundMusic,
}) async {
  if (clipPaths.isEmpty) return null;
  if (!minisMulticlipMergeSupported()) {
    if (context.mounted) {
      showMinisToast(
        context,
        'Merging clips requires Android, iOS, or macOS.',
      );
    }
    return null;
  }
  for (final path in clipPaths) {
    if (!File(path).existsSync()) {
      if (context.mounted) {
        showMinisToast(context, 'Clip missing: $path');
      }
      return null;
    }
  }

  if (clipPaths.length == 1 &&
      playbackSpeed == 1.0 &&
      enableAudio == true &&
      (backgroundMusic == null || backgroundMusic.path.trim().isEmpty)) {
    return clipPaths.first;
  }

  final id = DateTime.now().microsecondsSinceEpoch.toString();
  final tempDir = await getTemporaryDirectory();
  final outPath = p.join(tempDir.path, 'minis_reel_$id.mp4');
  final safeClipPaths = await _sanitizeClipPathsForIos(clipPaths);

  final twoPass = _needsMusicTempoPass(playbackSpeed, backgroundMusic);
  final progressBus = StreamController<double>.broadcast();
  final activeTask = _ActiveTaskRef();

  Future<String?> runner() async {
    if (!twoPass) {
      // Single-pass path: music absent or speed == 1.0, no tempo conflict.
      List<VideoAudioTrack> audioTracks = const [];
      final seg = backgroundMusic;
      final music = seg?.path.trim();
      if (music != null && music.isNotEmpty) {
        final audioFile = File(music);
        if (!audioFile.existsSync()) {
          if (context.mounted) {
            showMinisToast(context, 'Music file not found: $music');
          }
        } else {
          audioTracks = [
            VideoAudioTrack(
              path: music,
              volume: 1.0,
              loop: true,
              audioStartTime: Duration(milliseconds: seg!.startMs),
              audioEndTime: Duration(milliseconds: seg.endMs),
            ),
          ];
        }
      }

      final duckClipAudio = audioTracks.isNotEmpty;
      final clipVolume = duckClipAudio ? (enableAudio ? 0.35 : 0.0) : null;

      final data = _buildSinglePassData(
        id: id,
        safeClipPaths: safeClipPaths,
        playbackSpeed: playbackSpeed,
        enableAudio: enableAudio,
        audioTracks: audioTracks,
        clipVolume: clipVolume,
      );
      activeTask.id = data.id;
      final sub = _pipeProgress(
        taskId: data.id, sink: progressBus, offset: 0.0, scale: 1.0,
      );
      try {
        await ProVideoEditor.instance.renderVideoToFile(outPath, data);
      } finally {
        await sub.cancel();
      }
      return outPath;
    }

    // Two-pass path: render speed-adjusted video first, then mux music at 1.0×.
    final workDir = await _intermediateWorkDir();
    final pass1Path = p.join(workDir.path, 'minis_pass1_$id.mp4');
    final id1 = '${id}_p1';
    final id2 = '${id}_p2';

    final pass1Data = _buildPassOneData(
      id: id1,
      safeClipPaths: safeClipPaths,
      playbackSpeed: playbackSpeed,
      enableAudio: enableAudio,
    );
    activeTask.id = pass1Data.id;
    final sub1 = _pipeProgress(
      taskId: pass1Data.id, sink: progressBus, offset: 0.0, scale: 0.5,
    );
    try {
      await ProVideoEditor.instance.renderVideoToFile(pass1Path, pass1Data);
    } finally {
      await sub1.cancel();
    }

    final pass2Data = _buildPassTwoData(
      id: id2,
      passOnePath: pass1Path,
      enableAudio: enableAudio,
      music: backgroundMusic!,
    );
    activeTask.id = pass2Data.id;
    final sub2 = _pipeProgress(
      taskId: pass2Data.id, sink: progressBus, offset: 0.5, scale: 0.5,
    );
    try {
      await ProVideoEditor.instance.renderVideoToFile(outPath, pass2Data);
    } finally {
      await sub2.cancel();
      try { await File(pass1Path).delete(); } catch (_) {}
    }
    return outPath;
  }

  final future = runner();
  if (!context.mounted) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (_, __) {},
      ).whenComplete(() async {
        try { await progressBus.close(); } catch (_) {}
      }),
    );
    return null;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => _MinisClipMergeProgressDialog(
      progressStream: progressBus.stream,
      renderFuture: future,
      canCancel: _mergeCancelSupported(),
      onCancel: () async {
        final tid = activeTask.id;
        if (tid != null) {
          await ProVideoEditor.instance.cancel(tid);
        }
      },
    ),
  );

  try {
    final result = await future;
    if (result == null) return null;
    final finalPath = await _copyToDocumentsIfIos(result);
    _logMergedVideoFileProbe(finalPath);
    return finalPath;
  } on RenderCanceledException {
    return null;
  } catch (e, st) {
    dev.log('minis merge failed: $e', error: e, stackTrace: st, name: 'MinisMerge');
    if (clipPaths.length == 1 && !twoPass) {
      dev.log('minis merge fallback to original clip', name: 'MinisMerge');
      return clipPaths.first;
    }
    rethrow;
  } finally {
    try { await progressBus.close(); } catch (_) {}
  }
}

/// Silent merge — no dialog. Use this when the caller already shows its own
/// loading overlay (e.g. LoopIt's runWithMinisHandoffOverlay).
/// Returns output path on success, or `null` on error.
Future<String?> mergeMinisVideoClipsSilent({
  required List<String> clipPaths,
  required double playbackSpeed,
  required bool enableAudio,
  MinisMusicSegment? backgroundMusic,
}) async {
  if (clipPaths.isEmpty) return null;
  if (!minisMulticlipMergeSupported()) return null;
  for (final path in clipPaths) {
    if (!File(path).existsSync()) return null;
  }

  if (clipPaths.length == 1 &&
      playbackSpeed == 1.0 &&
      enableAudio == true &&
      (backgroundMusic == null || backgroundMusic.path.trim().isEmpty)) {
    return clipPaths.first;
  }

  final id = DateTime.now().microsecondsSinceEpoch.toString();
  final tempDir = await getTemporaryDirectory();
  final outPath = p.join(tempDir.path, 'minis_reel_$id.mp4');
  final safeClipPaths = await _sanitizeClipPathsForIos(clipPaths);

  final twoPass = _needsMusicTempoPass(playbackSpeed, backgroundMusic);

  StreamSubscription<double>? overlaySub;
  final progressBus = StreamController<double>.broadcast();
  if (MinisCaptureHost.hasHandoffOverlay) {
    overlaySub = progressBus.stream.listen((v) {
      MinisCaptureHost.updateHandoffProgress(v);
    });
  }

  Future<void> closeBus() async {
    try { await overlaySub?.cancel(); } catch (_) {}
    try { await progressBus.close(); } catch (_) {}
  }

  try {
    if (!twoPass) {
      List<VideoAudioTrack> audioTracks = const [];
      final seg = backgroundMusic;
      final music = seg?.path.trim();
      if (music != null && music.isNotEmpty && File(music).existsSync()) {
        audioTracks = [
          VideoAudioTrack(
            path: music,
            volume: 1.0,
            loop: true,
            audioStartTime: Duration(milliseconds: seg!.startMs),
            audioEndTime: Duration(milliseconds: seg.endMs),
          ),
        ];
      }
      final duckClipAudio = audioTracks.isNotEmpty;
      final clipVolume = duckClipAudio ? (enableAudio ? 0.35 : 0.0) : null;

      final data = _buildSinglePassData(
        id: id,
        safeClipPaths: safeClipPaths,
        playbackSpeed: playbackSpeed,
        enableAudio: enableAudio,
        audioTracks: audioTracks,
        clipVolume: clipVolume,
      );
      final sub = _pipeProgress(
        taskId: data.id, sink: progressBus, offset: 0.0, scale: 1.0,
      );
      try {
        await ProVideoEditor.instance.renderVideoToFile(outPath, data);
      } finally {
        await sub.cancel();
      }
    } else {
      final workDir = await _intermediateWorkDir();
      final pass1Path = p.join(workDir.path, 'minis_pass1_$id.mp4');

      final pass1Data = _buildPassOneData(
        id: '${id}_p1',
        safeClipPaths: safeClipPaths,
        playbackSpeed: playbackSpeed,
        enableAudio: enableAudio,
      );
      final sub1 = _pipeProgress(
        taskId: pass1Data.id, sink: progressBus, offset: 0.0, scale: 0.5,
      );
      try {
        await ProVideoEditor.instance.renderVideoToFile(pass1Path, pass1Data);
      } finally {
        await sub1.cancel();
      }

      final pass2Data = _buildPassTwoData(
        id: '${id}_p2',
        passOnePath: pass1Path,
        enableAudio: enableAudio,
        music: backgroundMusic!,
      );
      final sub2 = _pipeProgress(
        taskId: pass2Data.id, sink: progressBus, offset: 0.5, scale: 0.5,
      );
      try {
        await ProVideoEditor.instance.renderVideoToFile(outPath, pass2Data);
      } finally {
        await sub2.cancel();
        try { await File(pass1Path).delete(); } catch (_) {}
      }
    }

    final finalPath = await _copyToDocumentsIfIos(outPath);
    _logMergedVideoFileProbe(finalPath);
    return finalPath;
  } on RenderCanceledException {
    return null;
  } catch (e, st) {
    dev.log('minis merge silent failed: $e', error: e, stackTrace: st, name: 'MinisMerge');
    if (clipPaths.length == 1 && !twoPass) {
      dev.log('minis merge silent fallback to original clip', name: 'MinisMerge');
      return clipPaths.first;
    }
    if (MinisCaptureHost.hasHandoffOverlay) {
      MinisCaptureHost.reportHandoffError(minisUserFriendlyException(e));
    }
    rethrow;
  } finally {
    await closeBus();
  }
}


class _MinisClipMergeProgressDialog extends StatefulWidget {
  const _MinisClipMergeProgressDialog({
    required this.progressStream,
    required this.renderFuture,
    required this.canCancel,
    required this.onCancel,
  });

  final Stream<double> progressStream;
  final Future<String?> renderFuture;
  final bool canCancel;
  final Future<void> Function() onCancel;

  @override
  State<_MinisClipMergeProgressDialog> createState() =>
      _MinisClipMergeProgressDialogState();
}

class _MinisClipMergeProgressDialogState
    extends State<_MinisClipMergeProgressDialog> {
  double _simulatedProgress = 0.0;
  Timer? _simTimer;

  @override
  void initState() {
    super.initState();
    // Native FFmpeg often stalls at 0% when duration metadata is missing.
    // Simulate progress up to 92% over ~45 seconds so the UI isn't dead.
    _simTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        if (_simulatedProgress < 0.92) {
          // Slows down as it gets closer to 90%
          _simulatedProgress += 0.01 * (1.0 - _simulatedProgress);
        }
      });
    });

    widget.renderFuture.whenComplete(() {
      _simTimer?.cancel();
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      title: const Text(
        'Merging clips',
        style: TextStyle(color: Colors.white),
      ),
      content: StreamBuilder<double>(
        stream: widget.progressStream,
        builder: (context, snap) {
          double? nativeProgress = snap.data;

          if (nativeProgress != null && nativeProgress > 0.01) {
            // Native stream is working correctly, stop simulation.
            _simTimer?.cancel();
          } else {
            // Use simulation if native is stuck at 0 or null.
            nativeProgress = _simulatedProgress;
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              SizedBox(
                width: 84,
                height: 84,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: nativeProgress,
                      strokeWidth: 4,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                    Text(
                      '${(nativeProgress * 100).toInt()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Combining segments…',
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
            ],
          );
        },
      ),
      actions: [
        if (widget.canCancel)
          TextButton(
            onPressed: () {
              _simTimer?.cancel();
              widget.onCancel();
            },
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
      ],
    );
  }
}
