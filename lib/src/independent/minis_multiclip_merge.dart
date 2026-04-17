import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import 'package:loopit_minis/src/independent/minis_music_segment.dart';
import 'package:loopit_minis/src/session_and_toast.dart';

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
  @override
  void initState() {
    super.initState();
    widget.renderFuture.whenComplete(() {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Merging clips'),
      content: StreamBuilder<ProgressModel>(
        stream: ProVideoEditor.instance.progressStreamById(widget.taskId),
        builder: (context, snap) {
          final v = snap.data?.progress;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (v != null)
                LinearProgressIndicator(value: v)
              else
                const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(v != null ? '${(v * 100).toStringAsFixed(0)}%' : 'Starting'),
            ],
          );
        },
      ),
      actions: [
        if (widget.canCancel)
          TextButton(
            onPressed: () => widget.onCancel(),
            child: const Text('Cancel'),
          ),
      ],
    );
  }
}
