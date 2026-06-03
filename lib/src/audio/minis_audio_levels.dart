import 'dart:async';

import 'minis_audio_channel.dart';

class MinisAudioLevels {
  const MinisAudioLevels({
    required this.peakDb,
    required this.rmsDb,
    required this.timestampMs,
  });

  final double peakDb;
  final double rmsDb;
  final int timestampMs;

  factory MinisAudioLevels.fromEvent(Map<dynamic, dynamic> e) =>
      MinisAudioLevels(
        peakDb: (e['peakDb'] as num?)?.toDouble() ?? -80.0,
        rmsDb: (e['rmsDb'] as num?)?.toDouble() ?? -80.0,
        timestampMs: (e['ts'] as num?)?.toInt() ?? 0,
      );
}

class MinisAudioLevelStream {
  MinisAudioLevelStream._();
  static final MinisAudioLevelStream instance = MinisAudioLevelStream._();

  Stream<MinisAudioLevels>? _cached;

  Stream<MinisAudioLevels> stream() {
    _cached ??= minisAudioLevels.receiveBroadcastStream().map((raw) {
      if (raw is Map) return MinisAudioLevels.fromEvent(raw);
      return const MinisAudioLevels(peakDb: -80, rmsDb: -80, timestampMs: 0);
    }).asBroadcastStream();
    return _cached!;
  }
}
