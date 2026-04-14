import 'dart:math' as math;

/// LoopIt-style mapping: scroll offset to start of the visible window (ms).
///
/// [oneBarValue] is bars per second (same as LoopIt barInBoxCount / windowSeconds).
int minisMusicTrimStartMsFromScroll({
  required double scrollOffsetPx,
  required double barTotalWidth,
  required double oneBarValue,
  required int audioDurationMs,
  required int windowMs,
}) {
  if (barTotalWidth <= 0 || oneBarValue <= 0 || audioDurationMs <= 0) {
    return 0;
  }
  final w = math.max(1, windowMs);
  final maxStartMs = math.max(0, audioDurationMs - w);
  final maxStartSec = maxStartMs ~/ 1000;
  var startSec =
      ((scrollOffsetPx / barTotalWidth) / oneBarValue).floor().clamp(0, maxStartSec);
  return startSec * 1000;
}

/// Maximum [ScrollController] offset so the window stays within the file.
double minisMusicTrimMaxScrollOffset({
  required double barTotalWidth,
  required double oneBarValue,
  required int audioDurationMs,
  required int windowMs,
}) {
  if (barTotalWidth <= 0 || oneBarValue <= 0 || audioDurationMs <= 0) {
    return 0;
  }
  final w = math.max(1, windowMs);
  final maxStartMs = math.max(0, audioDurationMs - w);
  final maxStartSec = maxStartMs ~/ 1000;
  return maxStartSec * barTotalWidth * oneBarValue;
}

/// Scroll offset for [startMs] on the same second grid as [minisMusicTrimStartMsFromScroll].
///
/// Used to restore the slider when re-opening the trim sheet (LoopIt `animateTo` behavior).
double minisMusicTrimScrollOffsetForStartMs({
  required int startMs,
  required double barTotalWidth,
  required double oneBarValue,
  required int audioDurationMs,
  required int windowMs,
}) {
  if (barTotalWidth <= 0 || oneBarValue <= 0 || audioDurationMs <= 0) {
    return 0;
  }
  final maxOff = minisMusicTrimMaxScrollOffset(
    barTotalWidth: barTotalWidth,
    oneBarValue: oneBarValue,
    audioDurationMs: audioDurationMs,
    windowMs: windowMs,
  );
  final w = math.max(1, windowMs);
  final maxStartMs = math.max(0, audioDurationMs - w);
  final maxStartSec = maxStartMs ~/ 1000;
  var startSec = (startMs / 1000).floor().clamp(0, maxStartSec);
  final off = startSec * barTotalWidth * oneBarValue;
  return off.clamp(0.0, maxOff);
}

// --- Linear scrub (min travel) — fixes ~2px scroll when track barely exceeds cap ---

/// Maps scroll 0…[maxScrollPx] → start time 0…[maxStartMs] (ms).
int minisMusicTrimStartMsFromScrollLinear({
  required double scrollOffsetPx,
  required double maxScrollPx,
  required int maxStartMs,
}) {
  if (maxScrollPx <= 0 || maxStartMs <= 0) return 0;
  return (scrollOffsetPx / maxScrollPx * maxStartMs).round().clamp(0, maxStartMs);
}

/// Inverse of [minisMusicTrimStartMsFromScrollLinear].
double minisMusicTrimScrollOffsetForStartMsLinear({
  required int startMs,
  required double maxScrollPx,
  required int maxStartMs,
}) {
  if (maxScrollPx <= 0 || maxStartMs <= 0) return 0;
  return (startMs / maxStartMs * maxScrollPx).clamp(0.0, maxScrollPx);
}

/// Inner width of the faux waveform row (pads added separately in the sheet).
///
/// Matches LoopIt [WaveSlider]: the scrollable row is at least [boxWidthPx]
/// (the selection frame) and as wide as all bars — one bar per
/// `1/oneBarValue` seconds of audio, so the **entire** file spans the track.
double minisMusicTrimInnerTrackWidthPx({
  required double boxWidthPx,
  required int waveBarCount,
  required double barTotalWidth,
}) {
  final barsW = waveBarCount * barTotalWidth;
  return math.max(boxWidthPx, barsW);
}

/// Horizontal [ScrollView] max offset for symmetric side padding around [boxWidthPx].
double minisMusicTrimMaxScrollForViewport({
  required double viewportWidthPx,
  required double boxWidthPx,
  required double innerTrackWidthPx,
}) {
  final side = math.max(0.0, viewportWidthPx / 2 - boxWidthPx / 2);
  final contentW = 2 * side + innerTrackWidthPx;
  return math.max(0.0, contentW - viewportWidthPx);
}
