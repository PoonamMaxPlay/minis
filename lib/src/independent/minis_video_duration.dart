import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:video_player/video_player.dart';

/// Resolves playback length for a local file.
///
/// [ProVideoEditor.instance.getMetadata] sometimes reports ~1s (or zero) for
/// gallery MP4s while [VideoPlayerController] matches what the user sees in
/// preview; use this for clip duration and caps.
Future<int> minisResolveVideoDurationMs(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) return 0;

  final fromPlayer = await _durationMsViaVideoPlayer(file);
  int metaMs = 0;
  try {
    final meta =
        await ProVideoEditor.instance.getMetadata(EditorVideo.file(file));
    metaMs = meta.duration.inMilliseconds.clamp(0, 1 << 30);
  } catch (_) {}

  // Some files report ~1s on one codec path and a sane value on the other.
  return math.max(fromPlayer, metaMs);
}

/// Like [minisResolveVideoDurationMs], but retries a few times when the first
/// read is suspiciously short (fresh exports often report ~1s until metadata is
/// readable).
Future<int> minisResolveVideoDurationMsBestEffort(String filePath) async {
  var best = await minisResolveVideoDurationMs(filePath);
  if (best >= 2000) {
    return best;
  }
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final next = await minisResolveVideoDurationMs(filePath);
    if (next > best) {
      best = next;
    }
    if (best >= 2000) {
      break;
    }
  }
  return best;
}

/// Picks a wall-time / trim-span duration vs a probed file duration.
///
/// Callers may already know a trustworthy length (camera wall clock, trim
/// selection). Probing can still return ~1s on new files; in that case keep
/// [reportedMs].
int minisCoalesceClipDurationMs(int reportedMs, int probedMs) {
  final r = reportedMs.clamp(1, 1 << 30);
  if (probedMs <= 0) {
    return r;
  }
  if (probedMs < 2000 && r > probedMs * 3) {
    return r;
  }
  return math.max(r, probedMs);
}

/// Resolves final clip length for multi-clip reels: combines [reportedMs] (camera
/// wall clock, trim span, or preview player) with file probes.
///
/// A single probe often returns ~1000ms for MP4s until the container is fully
/// readable � especially on **second and later** appends in one session. This
/// runs a second pass after a short delay when the first pass is still short.
Future<int> minisFinalizeClipDurationMs(int reportedMs, String filePath) async {
  final r = reportedMs.clamp(1, 1 << 30);
  var probed = await minisResolveVideoDurationMsBestEffort(filePath);
  var ms = minisCoalesceClipDurationMs(r, probed);
  if (ms >= 2000) {
    return ms;
  }
  await Future<void>.delayed(const Duration(milliseconds: 750));
  probed = await minisResolveVideoDurationMs(filePath);
  ms = minisCoalesceClipDurationMs(r, math.max(ms, probed));
  if (ms >= 2000) {
    return ms;
  }
  probed = await minisResolveVideoDurationMsBestEffort(filePath);
  ms = minisCoalesceClipDurationMs(r, math.max(ms, probed));
  return math.max(1, ms);
}

Future<int> _durationMsViaVideoPlayer(File file) async {
  final controller = VideoPlayerController.file(file);
  try {
    await controller.initialize();

    var ms = controller.value.duration.inMilliseconds;
    if (ms > 0) return ms;

    final completer = Completer<void>();
    void listener() {
      final d = controller.value.duration.inMilliseconds;
      if (d > 0 && !completer.isCompleted) completer.complete();
    }

    controller.addListener(listener);
    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Duration still unknown: nudge decoders that update after first frames.
      try {
        await controller.setVolume(0);
        await controller.seekTo(Duration.zero);
        await controller.play();
        for (var i = 0; i < 40; i++) {
          ms = controller.value.duration.inMilliseconds;
          if (ms > 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await controller.pause();
      } catch (_) {}
    } finally {
      controller.removeListener(listener);
    }

    ms = controller.value.duration.inMilliseconds;
    return ms > 0 ? ms : 0;
  } catch (e, st) {
    debugPrint('minisResolveVideoDurationMs: VideoPlayer failed: $e\n$st');
    return 0;
  } finally {
    await controller.dispose();
  }
}

/// Waits until [controller] reports a positive duration (some Android files
/// expose length only after buffering).
Future<void> minisWaitForVideoControllerDuration(
  VideoPlayerController controller, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (controller.value.duration.inMilliseconds > 0) return;

  final completer = Completer<void>();
  void listener() {
    if (controller.value.duration.inMilliseconds > 0 &&
        !completer.isCompleted) {
      completer.complete();
    }
  }

  controller.addListener(listener);
  try {
    await completer.future.timeout(timeout);
  } catch (_) {
    try {
      await controller.setVolume(0);
      await controller.seekTo(Duration.zero);
      await controller.play();
      for (var i = 0; i < 50; i++) {
        if (controller.value.duration.inMilliseconds > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await controller.pause();
    } catch (_) {}
  } finally {
    controller.removeListener(listener);
  }
}
