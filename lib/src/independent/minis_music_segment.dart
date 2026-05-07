import 'package:flutter/foundation.dart';

/// User-chosen slice of an audio file for reel background / guide playback.
///
/// [path] must be a **readable filesystem path** that [audio_waveforms] and the
/// merge pipeline can open (e.g. materialized copy from the picker). The trim
/// sheet returns the path it successfully prepared for playback.
class MinisMusicSegment {
  const MinisMusicSegment({
    required this.path,
    required this.startMs,
    required this.endMs,
  }) : assert(startMs >= 0),
       assert(endMs >= startMs);

  final String path;
  final int startMs;
  final int endMs;

  int get windowMs => endMs - startMs;

  Map<String, dynamic> toMap() => {
        'path': path,
        'startMs': startMs,
        'endMs': endMs,
      };

  factory MinisMusicSegment.fromMap(Map<String, dynamic> map) {
    return MinisMusicSegment(
      path: map['path'] as String? ?? '',
      startMs: (map['startMs'] as num?)?.toInt() ?? 0,
      endMs: (map['endMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// [audio_waveforms] player + trim UI are implemented for Android and iOS only.
bool minisAudioWaveformsTrimSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
