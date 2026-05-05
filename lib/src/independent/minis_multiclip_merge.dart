import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:retrytech_plugin/retrytech_plugin.dart';

import 'package:loopit_minis/src/independent/minis_music_segment.dart';
import 'package:loopit_minis/src/minis_capture_host.dart';
import 'package:loopit_minis/src/minis_user_message.dart';
import 'package:loopit_minis/src/session_and_toast.dart';

/// Same platforms as [proVideoEditorRenderExportSupported] in hub (no web).
bool minisMulticlipMergeSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}



/// Concatenate [clipPaths] with optional audio; shows progress dialog.
///
/// Uses the native video pipeline (Media3 Transformer / AVFoundation)
/// for hardware-accelerated merge with real progress reporting.
///
/// Returns output path on success, or `null` on cancel / unsupported / error.
/// Concatenate [clipPaths] with optional audio and speed; shows progress dialog.
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
      showMinisToast(context, 'Merging clips requires Android or iOS.');
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

  final dir = await getTemporaryDirectory();
  final outPath = p.join(
    dir.path,
    'minis_reel_${DateTime.now().microsecondsSinceEpoch}.mp4',
  );

  // Background music
  String? musicPath;
  int musicStartMs = 0;
  int musicEndMs = 0;
  double clipVolume = 1.0;
  final seg = backgroundMusic;
  final music = seg?.path.trim();
  if (music != null && music.isNotEmpty) {
    if (!File(music).existsSync()) {
      if (context.mounted) showMinisToast(context, 'Music file not found.');
    } else {
      musicPath = music;
      musicStartMs = seg!.startMs;
      musicEndMs = seg.endMs;
      clipVolume = enableAudio ? 0.15 : 0.0;
    }
  }

  final progressNotifier = ValueNotifier<double>(0.0);
  Completer<String?>? mergeCompleter;

  if (context.mounted) {
    mergeCompleter = Completer<String?>();

    // Start merge in background
    unawaited(_doNativeMerge(
      clipPaths: clipPaths,
      outPath: outPath,
      enableAudio: enableAudio,
      musicPath: musicPath,
      musicStartMs: musicStartMs,
      musicEndMs: musicEndMs,
      clipVolume: clipVolume,
      playbackSpeed: playbackSpeed,
      onProgress: (p) => progressNotifier.value = p,
    ).then((result) {
      if (!mergeCompleter!.isCompleted) mergeCompleter.complete(result);
    }).catchError((e) {
      if (!mergeCompleter!.isCompleted) mergeCompleter.complete(null);
    }));

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MinisClipMergeProgressDialog(
        progressNotifier: progressNotifier,
        mergeFuture: mergeCompleter!.future,
      ),
    );
  }

  final result = mergeCompleter != null
      ? await mergeCompleter.future
      : await _doNativeMerge(
          clipPaths: clipPaths,
          outPath: outPath,
          enableAudio: enableAudio,
          musicPath: musicPath,
          musicStartMs: musicStartMs,
          musicEndMs: musicEndMs,
          clipVolume: clipVolume,
          playbackSpeed: playbackSpeed,
        );

  progressNotifier.dispose();
  return result;
}

/// Shared native merge call.
Future<String?> _doNativeMerge({
  required List<String> clipPaths,
  required String outPath,
  required bool enableAudio,
  String? musicPath,
  int musicStartMs = 0,
  int musicEndMs = 0,
  double clipVolume = 1.0,
  double playbackSpeed = 1.0,
  void Function(double)? onProgress,
}) async {
  final result = await RetrytechPlugin.shared.mergeClips(
    clipPaths: clipPaths,
    outputPath: outPath,
    enableAudio: enableAudio,
    musicPath: musicPath,
    musicStartMs: musicStartMs,
    musicEndMs: musicEndMs,
    clipVolume: clipVolume,
    playbackSpeed: playbackSpeed,
    onProgress: onProgress,
  );
  if (result.isEmpty) return null;

  final outFile = File(result);
  if (!outFile.existsSync() || outFile.lengthSync() == 0) {
    debugPrint('[mergeMinisVideoClips] output missing or empty');
    return null;
  }
  return result;
}
/// Silent merge -- no dialog. Use this when the caller already shows its own
/// loading overlay (e.g. LoopIt's runWithMinisHandoffOverlay).
///
/// [qualityPreset] is accepted for API compatibility but ignored -- the native
/// pipeline always uses the device hardware encoder at source resolution.
///
/// Returns output path on success, or `null` on error.
Future<String?> mergeMinisVideoClipsSilent({
  required List<String> clipPaths,
  required double playbackSpeed,
  required bool enableAudio,
  MinisMusicSegment? backgroundMusic,
  dynamic qualityPreset,
}) async {
  if (clipPaths.isEmpty) return null;
  if (!minisMulticlipMergeSupported()) return null;
  for (final path in clipPaths) {
    if (!File(path).existsSync()) return null;
  }

  final dir = await getTemporaryDirectory();
  final outPath = p.join(
    dir.path,
    'minis_reel_${DateTime.now().microsecondsSinceEpoch}.mp4',
  );

  String? musicPath;
  int musicStartMs = 0;
  int musicEndMs = 0;
  double clipVolume = 1.0;
  final seg = backgroundMusic;
  final music = seg?.path.trim();
  if (music != null && music.isNotEmpty) {
    if (!File(music).existsSync()) {
      debugPrint('[mergeMinisVideoClipsSilent] WARNING: music file missing: $music');
    } else {
      musicPath = music;
      musicStartMs = seg!.startMs;
      musicEndMs = seg.endMs;
      clipVolume = enableAudio ? 0.15 : 0.0;
    }
  }

  try {
    final result = await _doNativeMerge(
      clipPaths: clipPaths,
      outPath: outPath,
      enableAudio: enableAudio,
      musicPath: musicPath,
      musicStartMs: musicStartMs,
      musicEndMs: musicEndMs,
      clipVolume: clipVolume,
      playbackSpeed: playbackSpeed,
      onProgress: MinisCaptureHost.hasHandoffOverlay
          ? (p) => MinisCaptureHost.updateHandoffProgress(p)
          : null,
    );
    return result;
  } catch (e) {
    if (MinisCaptureHost.hasHandoffOverlay) {
      MinisCaptureHost.reportHandoffError(minisUserFriendlyException(e));
    }
    rethrow;
  }
}


class _MinisClipMergeProgressDialog extends StatefulWidget {
  const _MinisClipMergeProgressDialog({
    required this.progressNotifier,
    required this.mergeFuture,
  });

  final ValueNotifier<double> progressNotifier;
  final Future<String?> mergeFuture;

  @override
  State<_MinisClipMergeProgressDialog> createState() =>
      _MinisClipMergeProgressDialogState();
}

class _MinisClipMergeProgressDialogState
    extends State<_MinisClipMergeProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.mergeFuture.whenComplete(() {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      title: const Text(
        'Merging clips',
        style: TextStyle(color: Colors.white),
      ),
      content: ValueListenableBuilder<double>(
        valueListenable: widget.progressNotifier,
        builder: (context, progress, _) {
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
                      value: progress,
                      strokeWidth: 4,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                    Text(
                      '${(progress * 100).toInt()}%',
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
      actions: const [],
    );
  }
}
