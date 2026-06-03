import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:loopit_minis/src/sys/video_player_shim.dart';

import 'package:loopit_minis/src/videdit/videdit_engine.dart';

/// Duration from the native engine's media probe only (no extra
/// [VideoPlayer]). Fast; pair with preview duration. Returns 0 when the
/// native engine is unavailable (Phase 1 scaffold).
Future<int> minisResolveVideoDurationMsMetadataOnly(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) return 0;
  return _probeViaEngine(file)
      .timeout(const Duration(seconds: 3), onTimeout: () => 0);
}

/// Resolves playback length for a local file.
///
/// The native engine's probe sometimes reports ~1s (or zero) for gallery
/// MP4s while [VideoPlayerController] matches what the user sees in
/// preview; use this for clip duration and caps.
Future<int> minisResolveVideoDurationMs(String filePath) async {
  final file = File(filePath);
  if (!await file.exists()) return 0;

  // Try the engine probe first so we do not wait on [VideoPlayer] when the
  // native side already knows duration (common for gallery MP4s).
  final metaMs = await _probeViaEngine(file)
      .timeout(const Duration(seconds: 2), onTimeout: () => 0);

  // If metadata is already valid and "long", we can skip the expensive player probe.
  if (metaMs > 2000) return metaMs;

  final fromPlayer = await _durationMsViaVideoPlayer(file);
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
  // Gallery / fresh exports often report ~0-1s until the container is readable.
  const delays = <int>[250, 400, 550];
  for (var i = 0; i < delays.length; i++) {
    await Future<void>.delayed(Duration(milliseconds: delays[i]));
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

/// Android often reports **~1000ms** until the container is fully parsed; for a
/// multi-MB file that is almost never the real length. Used after normal probes.
/// NOTE: only used for freshly recorded camera clips, never for gallery files.
Future<int> _extendDurationIfLargeFileLooksTooShort(
  String filePath,
  int reportedMs,
  int ms,
) async {
  final file = File(filePath);
  if (!await file.exists()) return ms;
  final len = await file.length();
  if (len < 48 * 1024) return ms;
  if (ms > 2200) return ms;

  var best = ms;
  if (reportedMs >= 4000 && best >= 2000 && best >= reportedMs ~/ 2) {
    return best;
  }
  const waits = <int>[400, 1100, 2200];
  for (final w in waits) {
    await Future<void>.delayed(Duration(milliseconds: w));
    final p = await minisResolveVideoDurationMsBestEffort(filePath);
    best = minisCoalesceClipDurationMs(reportedMs, math.max(best, p));
    if (best >= 5000) {
      break;
    }
    if (reportedMs >= 3000 && best >= 2500) {
      break;
    }
  }
  return best;
}

/// Refines a suspiciously short first probe before trim/cap decisions on
/// gallery imports.
Future<int> minisRefineGalleryPreflightProbeMs(
  String filePath,
  int probeMs,
) async {
  if (probeMs >= 2500) return probeMs;
  final file = File(filePath);
  if (!await file.exists()) return probeMs;
  final len = await file.length();
  if (len < 48 * 1024) return probeMs;
  await Future<void>.delayed(const Duration(milliseconds: 700));
  final p = await minisResolveVideoDurationMsBestEffort(filePath);
  return math.max(probeMs, p);
}

// ---------------------------------------------------------------------------
// Fast-path probe for gallery / pre-existing files
// ---------------------------------------------------------------------------

/// Resolves duration for a **gallery-picked or pre-existing** file in one fast
/// concurrent probe (typical: 100-400 ms, hard cap 2 s).
///
/// Gallery videos are fully written on disk and never have the "fresh export
/// ~1 s placeholder" problem that camera clips do. Both the native engine
/// probe and VideoPlayer are started in parallel; the best result wins.
Future<int> _resolveGalleryFileDurationMs(
  String filePath,
  int reportedMs,
) async {
  if (kDebugMode) debugPrint('\n=== MINIS DURATION PROBE START ===');
  if (kDebugMode) debugPrint('Path: $filePath');
  if (kDebugMode) debugPrint('Reported: $reportedMs');
  
  final file = File(filePath);
  if (!await file.exists()) {
    if (kDebugMode) debugPrint('ERROR: File does not exist! Returning ${math.max(reportedMs, 1)}');
    return math.max(reportedMs, 1);
  }

  final startTime = DateTime.now();

  final metaFuture =
      _probeViaEngine(file).timeout(const Duration(seconds: 3), onTimeout: () => 0);
  final playerFuture = _durationMsViaVideoPlayer(file)
      .timeout(const Duration(seconds: 6), onTimeout: () => 0);

  int best = 0;
  try {
    if (kDebugMode) debugPrint('Racing probers (early exit on first valid)...');

    final completer = Completer<int>();
    int completedCount = 0;
    const int totalProbers = 2;

    void checkDone(int val) {
      if (val > best) best = val;
      completedCount++;
      if (!completer.isCompleted) {
        if (best > 1000 && completedCount >= 1) {
          completer.complete(best);
        } else if (completedCount == totalProbers) {
          completer.complete(best);
        }
      }
    }

    metaFuture.then((v) => checkDone(v)).catchError((_) => checkDone(0));
    playerFuture.then((v) => checkDone(v)).catchError((_) => checkDone(0));

    best = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        if (kDebugMode) debugPrint('ERROR: Race timed out, using best=$best');
        return best;
      },
    );
    if (kDebugMode) debugPrint('Race completed. Best raw probe: $best');
  } catch (e, st) {
    if (kDebugMode) debugPrint('ERROR: Exception during race: $e\n$st');
  }

  if (best <= 2000) {
    final len = await file.length();
    if (len > 48 * 1024) {
      // Estimate based on an average bitrate of ~312 KB/sec for a 720p H.264 file.
      // (1 MB = ~3 seconds, so ~340 KB/sec). We use 280 KB/sec to be safe.
      final estimatedSec = len / (280 * 1024);
      int fallbackMs = (estimatedSec * 1000).toInt();
      if (fallbackMs > 180000) fallbackMs = 180000;
      if (fallbackMs < 5000) fallbackMs = 5000;
      
      if (kDebugMode) debugPrint('MINIS: Probes failed/returned $best for a large file ($len bytes). Estimated ${fallbackMs}ms.');
      best = fallbackMs;
    } else if (best <= 0) {
      if (kDebugMode) debugPrint('MINIS: Probes failed to read metadata. Using reported duration.');
      best = math.max(reportedMs, 1);
    }
  }

  final endTime = DateTime.now();
  if (kDebugMode) debugPrint('Probes took ${endTime.difference(startTime).inMilliseconds}ms. Best raw probe: $best');

  final coalesced = minisCoalesceClipDurationMs(
    math.max(reportedMs, 1),
    best,
  );
  
  if (kDebugMode) debugPrint('Final coalesced duration: $coalesced');
  if (kDebugMode) debugPrint('=== MINIS DURATION PROBE END ===\n');
  return math.max(coalesced, 1);
}

Future<int> _probeViaEngine(File file) async {
  if (!MinisVidEdit.instance.isAvailableSync) return 0;
  try {
    if (kDebugMode) debugPrint('[_probeViaEngine] Starting native probe...');
    final meta = await MinisVidEdit.instance
        .probe(file.path)
        .timeout(const Duration(seconds: 3));
    if (meta == null) return 0;
    if (kDebugMode) debugPrint('[_probeViaEngine] duration=${meta.durationMs}ms');
    return meta.durationMs.clamp(0, 1 << 30);
  } catch (e, st) {
    if (kDebugMode) debugPrint('[_probeViaEngine] Failed: $e\n$st');
    return 0;
  }
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

/// Resolves final clip length for multi-clip reels.
///
/// **[fromGalleryFile] = true** — gallery / media-library pick. File is
/// pre-existing and fully written, so the heavy retry loops are skipped.
/// A single fast concurrent probe runs (typical 100-400 ms, max 2 s).
///
/// **[fromGalleryPreview] = true** — the preview player already reported a
/// duration >= 3000 ms. Also uses the fast path since the file is known-good.
///
/// **Default** (camera clip) — keeps the original retry strategy because
/// container metadata may genuinely be unavailable for several seconds after
/// recording stops.
Future<int> minisFinalizeClipDurationMs(
  int reportedMs,
  String filePath, {
  bool fromGalleryPreview = false,
  bool fromGalleryFile = false,
}) async {
  if (kDebugMode) {
    debugPrint('======================================');
    debugPrint('MINIS: minisFinalizeClipDurationMs');
    debugPrint('MINIS: reportedMs=$reportedMs, fromGalleryPreview=$fromGalleryPreview, fromGalleryFile=$fromGalleryFile');
    debugPrint('======================================');
  }
  
  // Fast path: gallery / media-library files are fully written.
  if (fromGalleryFile || fromGalleryPreview) {
    if (kDebugMode) debugPrint('MINIS: Using _resolveGalleryFileDurationMs (fast path)');
    return _resolveGalleryFileDurationMs(filePath, reportedMs);
  }

  if (kDebugMode) debugPrint('MINIS: Using slow path for freshly recorded clip');
  // Slow path: freshly recorded camera clip.
  final r = reportedMs.clamp(1, 1 << 30);
  var probed = await minisResolveVideoDurationMsBestEffort(filePath);
  var ms = minisCoalesceClipDurationMs(r, probed);
  if (ms >= 2000) {
    ms = await _extendDurationIfLargeFileLooksTooShort(filePath, r, ms);
    return math.max(1, ms);
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  probed = await minisResolveVideoDurationMs(filePath);
  ms = minisCoalesceClipDurationMs(r, math.max(ms, probed));
  if (ms >= 2000) {
    ms = await _extendDurationIfLargeFileLooksTooShort(filePath, r, ms);
    return math.max(1, ms);
  }
  probed = await minisResolveVideoDurationMsBestEffort(filePath);
  ms = minisCoalesceClipDurationMs(r, math.max(ms, probed));
  if (ms < 2000) {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    probed = await minisResolveVideoDurationMsBestEffort(filePath);
    ms = minisCoalesceClipDurationMs(r, math.max(ms, probed));
  }
  ms = await _extendDurationIfLargeFileLooksTooShort(filePath, r, ms);
  return math.max(1, ms);
}

/// Human-readable length for clip lists (e.g. `0:12`, `1:05`), not raw seconds.
///
/// Any positive [ms] shows at least `0:01` — half-second rounding can otherwise
/// show `0:00` for real clips (e.g. 400ms), which breaks multi-clip rows.
String minisFormatClipDurationLabel(int ms) {
  if (ms <= 0) return '0:00';
  var totalSec = (ms + 500) ~/ 1000;
  if (totalSec < 1) totalSec = 1;
  final m = totalSec ~/ 60;
  final s = totalSec % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

Future<int> _durationMsViaVideoPlayer(File file) async {
  final controller = VideoPlayerController.file(
    file,
    videoPlayerOptions: const VideoPlayerOptions(mixWithOthers: true),
  );
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
        for (var i = 0; i < 60; i++) {
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
