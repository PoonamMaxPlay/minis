import 'dart:async';

import 'minis_audio_channel.dart';

class MinisWaveformData {
  const MinisWaveformData({
    required this.peaks,
    required this.rms,
    required this.durationMs,
  });

  final List<double> peaks;
  final List<double> rms;
  final int durationMs;
}

/// Decode any platform-supported audio file → N peak/RMS pairs. Phase 1
/// implementation is straight PCM downsample on the native side.
class MinisWaveformExtractor {
  static Future<MinisWaveformData> extract({
    required String path,
    int peaks = 1024,
  }) async {
    final res = await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>(
      'extractWaveform',
      {'path': path, 'peaks': peaks},
    );
    final p = (res?['peaks'] as List?)?.cast<num>().map((e) => e.toDouble()).toList() ??
        const <double>[];
    final r = (res?['rms'] as List?)?.cast<num>().map((e) => e.toDouble()).toList() ??
        const <double>[];
    final d = (res?['durationMs'] as num?)?.toInt() ?? 0;
    return MinisWaveformData(peaks: p, rms: r, durationMs: d);
  }
}
