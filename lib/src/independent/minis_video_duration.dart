import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:retrytech_plugin/retrytech_plugin.dart';
import 'package:video_player/video_player.dart';

/// Video duration in milliseconds via single native call
/// (MediaMetadataRetriever on Android, AVAsset.duration on iOS).
/// Replaces the old 3-prober race.
Future<int> minisResolveVideoDurationMsMetadataOnly(String filePath) async {
  if (!await File(filePath).exists()) return 0;
  final ms = await RetrytechPlugin.shared.getVideoDurationMs(filePath);
  return ms > 0 ? ms : 0;
}

/// Resolves playback length for a local file via native API.
Future<int> minisResolveVideoDurationMs(String filePath) =>
    minisResolveVideoDurationMsMetadataOnly(filePath);

/// Best-effort duration probe. The native call is reliable so no retry needed.
Future<int> minisResolveVideoDurationMsBestEffort(String filePath) =>
    minisResolveVideoDurationMs(filePath);

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
  // Probe looks like noise (decoder not ready) but reported is clearly long.
  if (probedMs < 500 && r >= 2000) {
    return r;
  }
  // Reported looks like noise / timer glitch but probe read a long file.
  if (r < 500 && probedMs >= 5000) {
    return probedMs;
  }
  if (probedMs < 2000 && r > probedMs * 3) {
    return r;
  }
  return math.max(r, probedMs);
}

/// Resolves final clip length for multi-clip reels.
///
/// [fromGalleryFile] and [fromGalleryPreview] flags are accepted for API
/// compatibility but no longer affect behavior -- the native call is fast
/// and accurate for all sources.
Future<int> minisFinalizeClipDurationMs(
  int reportedMs,
  String filePath, {
  bool fromGalleryPreview = false,
  bool fromGalleryFile = false,
}) async {
  final probed = await minisResolveVideoDurationMs(filePath);
  final coalesced = minisCoalesceClipDurationMs(math.max(reportedMs, 1), probed);
  return math.max(coalesced, 1);
}

/// Refines a suspiciously short first probe for gallery imports.
Future<int> minisRefineGalleryPreflightProbeMs(
  String filePath,
  int probeMs,
) async {
  if (probeMs >= 2500) return probeMs;
  // Single retry -- native call is reliable but file might still be writing.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final ms = await minisResolveVideoDurationMs(filePath);
  return math.max(probeMs, ms);
}

/// Human-readable length for clip lists (e.g. `0:12`, `1:05`).
String minisFormatClipDurationLabel(int ms) {
  if (ms <= 0) return '0:00';
  var totalSec = (ms + 500) ~/ 1000;
  if (totalSec < 1) totalSec = 1;
  final m = totalSec ~/ 60;
  final s = totalSec % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
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

// ── Dead code below removed by native pipeline migration ──
// The following functions previously existed but are replaced by
// RetrytechPlugin.shared.getVideoDurationMs():
//   _resolveGalleryFileDurationMs, _probeViaMeta, _probeViaVideoCompress,
//   _durationMsViaVideoPlayer, _extendDurationIfLargeFileLooksTooShort
