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
import 'package:loopit_minis/src/session_and_toast.dart';
import 'package:video_player/video_player.dart' as vp;

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

  final id = DateTime.now().microsecondsSinceEpoch.toString();
  final dir = await getTemporaryDirectory();
  final outPath = p.join(dir.path, 'minis_reel_$id.mp4');

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

  // Use the same quality path as hub export: plain [VideoRenderData] omits
  // [qualityConfig]/bitrate and the encoder can fall back to a much lower
  // output than the camera-captured clips.
  // Explicit 1:1 scale skips [VideoRenderData.toAsyncMap]'s metadata-driven
  // fit (getMetadata on first segment). That probe can throw METADATA_ERROR
  // / setDataSource failures for some temp or gallery paths while export
  // would still succeed with fixed scales + quality bitrate.
  final data = VideoRenderData.withQualityPreset(
    id: id,
    videoSegments: clipPaths
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

  final future = ProVideoEditor.instance.renderVideoToFile(outPath, data);
  if (!context.mounted) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (_, __) {},
      ),
    );
    return null;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => _MinisClipMergeProgressDialog(
      taskId: data.id,
      renderFuture: future,
      canCancel: _mergeCancelSupported(),
      onCancel: () => ProVideoEditor.instance.cancel(data.id),
    ),
  );

  try {
    await future;
    _logMergedVideoFileProbe(outPath);
    return outPath;
  } on RenderCanceledException {
    return null;
  } catch (_) {
    rethrow;
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

  final id = DateTime.now().microsecondsSinceEpoch.toString();
  final dir = await getTemporaryDirectory();
  final outPath = p.join(dir.path, 'minis_reel_$id.mp4');

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

  final data = VideoRenderData.withQualityPreset(
    id: id,
    videoSegments: clipPaths
        .map((path) => VideoSegment(
              video: EditorVideo.file(File(path)),
              volume: clipVolume,
            ))
        .toList(),
    qualityPreset: VideoQualityPreset.p1080High,
    outputFormat: VideoOutputFormat.mp4,
    playbackSpeed: playbackSpeed,
    enableAudio: enableAudio,
    audioTracks: audioTracks,
    transform: const ExportTransform(scaleX: 1.0, scaleY: 1.0),
  );

  try {
    await ProVideoEditor.instance.renderVideoToFile(outPath, data);
    _logMergedVideoFileProbe(outPath);
    return outPath;
  } on RenderCanceledException {
    return null;
  } catch (_) {
    rethrow;
  }
}


class _MinisClipMergeProgressDialog extends StatefulWidget {
  const _MinisClipMergeProgressDialog({
    required this.taskId,
    required this.renderFuture,
    required this.canCancel,
    required this.onCancel,
  });

  final String taskId;
  final Future<void> renderFuture;
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
      title: const Text('Merging clips'),
      content: StreamBuilder<ProgressModel>(
        stream: ProVideoEditor.instance.progressStreamById(widget.taskId),
        builder: (context, snap) {
          double? nativeProgress = snap.data?.progress;
          
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
              LinearProgressIndicator(value: nativeProgress),
              const SizedBox(height: 12),
              Text('${(nativeProgress * 100).toStringAsFixed(0)}%'),
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
            child: const Text('Cancel'),
          ),
      ],
    );
  }
}
