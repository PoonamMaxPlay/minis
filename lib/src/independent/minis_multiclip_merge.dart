import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:loopit_minis/src/debug/video_aspect_log.dart';
import 'package:loopit_minis/src/sys/paths.dart';
import 'package:loopit_minis/src/independent/minis_music_segment.dart';
import 'package:loopit_minis/src/minis_capture_host.dart';
import 'package:loopit_minis/src/minis_user_message.dart';
import 'package:loopit_minis/src/session_and_toast.dart';
import 'package:loopit_minis/src/videdit/videdit_engine.dart';
import 'package:loopit_minis/src/videdit/videdit_types.dart';
import 'package:loopit_minis/src/sys/video_player_shim.dart' as vp;

/// iOS: AVAssetExportSession-derived helpers cannot read files from tmp/
/// during composition, and AVPlayer cannot play files from Library/Caches.
/// This helper copies any tmp/ clips to Documents and returns safe paths.
/// On Android this is a no-op — returns original paths unchanged.
Future<List<String>> _sanitizeClipPathsForIos(List<String> paths) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return paths;
  final basePath = await NativePaths.documentsDir();
  if (basePath == null) return paths;
  final dir = Directory(NativePaths.join([basePath, 'loopit_minis_captures']));
  if (!await dir.exists()) await dir.create(recursive: true);

  final result = <String>[];
  for (final path in paths) {
    if (path.contains('/tmp/') || path.contains('/Caches/')) {
      try {
        final ext = NativePaths.extension(path);
        final dest = NativePaths.join([
          dir.path,
          'minis_safe_${DateTime.now().microsecondsSinceEpoch}$ext',
        ]);
        await File(path).copy(dest);
        result.add(dest);
        try { await File(path).delete(); } catch (_) {}
      } catch (e) {
        dev.log('minis: clip copy failed for $path: $e', name: 'MinisMerge');
        result.add(path);
      }
    } else {
      result.add(path);
    }
  }
  return result;
}

Future<String> _copyToDocumentsIfIos(String cachePath) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return cachePath;
  try {
    final basePath = await NativePaths.documentsDir();
    if (basePath == null) return cachePath;
    final dir = Directory(NativePaths.join([basePath, 'loopit_minis_captures']));
    if (!await dir.exists()) await dir.create(recursive: true);
    final ext = NativePaths.extension(cachePath);
    final dest = NativePaths.join([
      dir.path,
      'minis_reel_${DateTime.now().microsecondsSinceEpoch}$ext',
    ]);
    await File(cachePath).copy(dest);
    try { await File(cachePath).delete(); } catch (_) {}
    return dest;
  } catch (e) {
    dev.log('minis: cache→docs copy failed: $e', name: 'MinisMerge');
    return cachePath;
  }
}

/// Phase 1: support gating now keys off the native engine availability.
/// Returns false when the native VidEdit engine is not built into this
/// binary. Callers should fall back to single-clip handoff or show a
/// "video editing tools rebuilding" message.
bool minisMulticlipMergeSupported() {
  if (kIsWeb) return false;
  if (!MinisVidEdit.instance.isPlatformEligible) return false;
  return MinisVidEdit.instance.isAvailableSync;
}

bool _mergeCancelSupported() => minisMulticlipMergeSupported();

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

/// Mutable holder so the cancel button can target whichever task is running.
class _ActiveTaskRef {
  String? id;
}

/// Concatenate [clipPaths] with [playbackSpeed] and optional audio; shows
/// progress. When [backgroundMusic] is set the engine mixes it in at the
/// timeline-native tempo (keepMusicTempo=true) so speed ramps do not
/// pitch-shift the music. Returns output path on success, or `null` on
/// cancel / unsupported / error.
Future<String?> mergeMinisVideoClipsWithDialog({
  required BuildContext context,
  required List<String> clipPaths,
  required double playbackSpeed,
  required bool enableAudio,
  MinisMusicSegment? backgroundMusic,
}) async {
  if (clipPaths.isEmpty) return null;

  // Native engine availability gates the entire merge path. When unavailable
  // we still allow the single-clip happy path so capture flows keep working.
  final engineReady = minisMulticlipMergeSupported();

  if (!engineReady) {
    if (clipPaths.length == 1 &&
        playbackSpeed == 1.0 &&
        enableAudio == true &&
        (backgroundMusic == null || backgroundMusic.path.trim().isEmpty)) {
      return clipPaths.first;
    }
    if (context.mounted) {
      showMinisToast(
        context,
        'Video editing tools are rebuilding on a native engine. '
        'Multi-clip merge will return in the next update.',
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
  final tempDirPath = await NativePaths.cacheDir();
  if (tempDirPath == null) return null;
  final outPath = NativePaths.join([tempDirPath, 'minis_reel_$id.mp4']);
  final safeClipPaths = await _sanitizeClipPathsForIos(clipPaths);

  final progressBus = StreamController<double>.broadcast();
  final activeTask = _ActiveTaskRef()..id = id;
  final progSub = MinisVidEdit.instance.progressFor(id).listen((evt) {
    if (!progressBus.isClosed) progressBus.add(evt.pct);
  });

  Future<String?> runner() async {
    final music = backgroundMusic;
    final keepTempo = playbackSpeed != 1.0 &&
        music != null &&
        music.path.trim().isNotEmpty &&
        File(music.path).existsSync();
    return MinisVidEdit.instance.concat(
      inputPaths: safeClipPaths,
      outputPath: outPath,
      speed: playbackSpeed,
      keepAudio: enableAudio,
      musicPath: music?.path,
      musicStartMs: music?.startMs ?? 0,
      musicEndMs: music?.endMs ?? 0,
      keepMusicTempo: keepTempo,
      taskId: id,
    );
  }

  final future = runner();
  if (!context.mounted) {
    unawaited(
      future.then<void>((_) {}, onError: (_, __) {}).whenComplete(() async {
        try { await progSub.cancel(); } catch (_) {}
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
          try { await MinisVidEdit.instance.cancelTask(tid); } catch (_) {}
        }
      },
    ),
  );

  try {
    final result = await future;
    if (result == null || result.isEmpty) return null;
    final finalPath = await _copyToDocumentsIfIos(result);
    _logMergedVideoFileProbe(finalPath);
    return finalPath;
  } on VidEditCancelled {
    return null;
  } on VidEditUnsupportedError {
    if (clipPaths.length == 1) {
      dev.log('minis merge engine unavailable, falling back to single clip',
          name: 'MinisMerge');
      return clipPaths.first;
    }
    if (context.mounted) {
      showMinisToast(context,
          'Video merge unavailable in this build. Pick one clip and continue.');
    }
    return null;
  } catch (e, st) {
    dev.log('minis merge failed: $e',
        error: e, stackTrace: st, name: 'MinisMerge');
    if (clipPaths.length == 1) {
      dev.log('minis merge fallback to original clip', name: 'MinisMerge');
      return clipPaths.first;
    }
    rethrow;
  } finally {
    try { await progSub.cancel(); } catch (_) {}
    try { await progressBus.close(); } catch (_) {}
  }
}

/// Silent merge — no dialog. Use this when the caller already shows its own
/// loading overlay (e.g. LoopIt's runWithMinisHandoffOverlay).
Future<String?> mergeMinisVideoClipsSilent({
  required List<String> clipPaths,
  required double playbackSpeed,
  required bool enableAudio,
  MinisMusicSegment? backgroundMusic,
}) async {
  if (clipPaths.isEmpty) return null;
  final engineReady = minisMulticlipMergeSupported();
  if (!engineReady) {
    if (clipPaths.length == 1 &&
        playbackSpeed == 1.0 &&
        enableAudio == true &&
        (backgroundMusic == null || backgroundMusic.path.trim().isEmpty)) {
      return clipPaths.first;
    }
    if (MinisCaptureHost.hasHandoffOverlay) {
      MinisCaptureHost.reportHandoffError(
        'Video editing tools are rebuilding on a native engine.',
      );
    }
    return null;
  }
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
  final tempDirPath = await NativePaths.cacheDir();
  if (tempDirPath == null) return null;
  final outPath = NativePaths.join([tempDirPath, 'minis_reel_$id.mp4']);
  final safeClipPaths = await _sanitizeClipPathsForIos(clipPaths);

  StreamSubscription<VidEditProgress>? progSub;
  if (MinisCaptureHost.hasHandoffOverlay) {
    progSub = MinisVidEdit.instance.progressFor(id).listen((evt) {
      MinisCaptureHost.updateHandoffProgress(evt.pct);
    });
  }

  try {
    final music = backgroundMusic;
    final keepTempo = playbackSpeed != 1.0 &&
        music != null &&
        music.path.trim().isNotEmpty &&
        File(music.path).existsSync();
    final result = await MinisVidEdit.instance.concat(
      inputPaths: safeClipPaths,
      outputPath: outPath,
      speed: playbackSpeed,
      keepAudio: enableAudio,
      musicPath: music?.path,
      musicStartMs: music?.startMs ?? 0,
      musicEndMs: music?.endMs ?? 0,
      keepMusicTempo: keepTempo,
      taskId: id,
    );
    final finalPath = await _copyToDocumentsIfIos(result);
    _logMergedVideoFileProbe(finalPath);
    return finalPath;
  } on VidEditCancelled {
    return null;
  } on VidEditUnsupportedError {
    if (clipPaths.length == 1) {
      dev.log('minis merge silent engine unavailable, fallback to single clip',
          name: 'MinisMerge');
      return clipPaths.first;
    }
    if (MinisCaptureHost.hasHandoffOverlay) {
      MinisCaptureHost.reportHandoffError(
        'Video merge unavailable in this build.',
      );
    }
    return null;
  } catch (e, st) {
    dev.log('minis merge silent failed: $e',
        error: e, stackTrace: st, name: 'MinisMerge');
    if (clipPaths.length == 1) {
      dev.log('minis merge silent fallback to original clip', name: 'MinisMerge');
      return clipPaths.first;
    }
    if (MinisCaptureHost.hasHandoffOverlay) {
      MinisCaptureHost.reportHandoffError(minisUserFriendlyException(e));
    }
    rethrow;
  } finally {
    try { await progSub?.cancel(); } catch (_) {}
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
    // Native engines can stall at 0% when duration metadata is missing.
    // Simulate progress up to 92% over ~45 seconds so the UI isn't dead.
    _simTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        if (_simulatedProgress < 0.92) {
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
            _simTimer?.cancel();
          } else {
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
