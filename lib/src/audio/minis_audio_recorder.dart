import 'dart:async';

import 'minis_audio_channel.dart';
import 'minis_audio_levels.dart';

enum MinisAudioFormat { aac, wav, opus, mp3 }

class MinisRecordResult {
  const MinisRecordResult({required this.path, required this.durationMs});
  final String path;
  final int durationMs;
}

/// Thin Dart-side wrapper for the native recorder. Phase 1 surface covers
/// start/pause/resume/stop. RNNoise / monitor / format upgrades land later.
class MinisAudioRecorder {
  bool _active = false;

  Future<void> start({
    required String path,
    MinisAudioFormat format = MinisAudioFormat.aac,
    int sampleRate = 44100,
    int channels = 1,
    int bitRate = 128000,
  }) async {
    await minisAudioChannel.invokeMethod('startRecord', {
      'path': path,
      'format': format.name,
      'sampleRate': sampleRate,
      'channels': channels,
      'bitRate': bitRate,
    });
    _active = true;
  }

  Future<void> pause() async {
    if (!_active) return;
    await minisAudioChannel.invokeMethod('pauseRecord');
  }

  Future<void> resume() async {
    if (!_active) return;
    await minisAudioChannel.invokeMethod('resumeRecord');
  }

  Future<MinisRecordResult> stop() async {
    final res =
        await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>('stopRecord');
    _active = false;
    return MinisRecordResult(
      path: (res?['path'] as String?) ?? '',
      durationMs: (res?['durationMs'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isActive => _active;

  Stream<MinisAudioLevels> levelStream() =>
      MinisAudioLevelStream.instance.stream();
}
