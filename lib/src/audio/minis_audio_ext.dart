import 'dart:async';

import 'package:flutter/services.dart';

import 'minis_audio_channel.dart';

/// Extended Dart surface for the deferred native ops listed in improvement4.md
/// (D1.x mic routing, D6 trim, D7 mix, D8 normalize, D9 pitch/stretch/beats).
/// Each call currently propagates the platform error so call sites can detect
/// the deferred state. Replace once the native impls land.

class MinisAudioInput {
  const MinisAudioInput({
    required this.id,
    required this.label,
    this.kind = 'unknown',
  });
  final String id;
  final String label;
  final String kind;

  factory MinisAudioInput.fromMap(Map m) => MinisAudioInput(
        id: (m['id']?.toString()) ?? '',
        label: (m['label']?.toString()) ?? '',
        kind: (m['kind']?.toString()) ?? 'unknown',
      );
}

class MinisAudioRouting {
  static Future<List<MinisAudioInput>> listInputs() async {
    try {
      final res = await minisAudioChannel
          .invokeMethod<Map<dynamic, dynamic>>('listInputs');
      final raw = (res?['inputs'] as List?) ?? const [];
      return raw
          .whereType<Map>()
          .map(MinisAudioInput.fromMap)
          .toList(growable: false);
    } on PlatformException catch (e) {
      if (e.code == 'NOT_IMPLEMENTED') return const [];
      rethrow;
    }
  }

  static Future<void> setInput({required String id, double gain = 1.0}) async {
    await minisAudioChannel.invokeMethod('setInput', {'id': id, 'gain': gain});
  }
}

class MinisAudioTrim {
  /// `mode`: "lossless" tries container-boundary cut; falls back to "accurate"
  /// (PCM decode + re-encode). Returns the output path.
  static Future<String> trim({
    required String path,
    required int inMs,
    required int outMs,
    required String outPath,
    String mode = 'accurate',
  }) async {
    final res = await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>(
      'trim',
      {
        'path': path,
        'inMs': inMs,
        'outMs': outMs,
        'outPath': outPath,
        'mode': mode,
      },
    );
    return (res?['path'] as String?) ?? outPath;
  }
}

class MinisMixTrack {
  const MinisMixTrack({
    required this.path,
    this.inMs = 0,
    this.outMs = 0,
    this.positionMs = 0,
    this.gainEnv = const [],
    this.panEnv = const [],
    this.eq,
  });
  final String path;
  final int inMs;
  final int outMs;
  final int positionMs;
  final List<List<double>> gainEnv;
  final List<List<double>> panEnv;
  final Map<String, double>? eq;

  Map<String, dynamic> toMap() => {
        'path': path,
        'inMs': inMs,
        'outMs': outMs,
        'positionMs': positionMs,
        'gainEnv': gainEnv,
        'panEnv': panEnv,
        if (eq != null) 'eq': eq,
      };
}

class MinisAudioMixer {
  static Future<String> mix({
    required List<MinisMixTrack> tracks,
    required String outPath,
    double targetLufs = -14.0,
  }) async {
    final res = await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>(
      'mix',
      {
        'tracks': tracks.map((t) => t.toMap()).toList(),
        'outPath': outPath,
        'targetLufs': targetLufs,
      },
    );
    return (res?['taskId'] as String?) ?? '';
  }

  static Future<void> normalize({
    required String path,
    required String outPath,
    double targetLufs = -14.0,
  }) async {
    await minisAudioChannel.invokeMethod('normalize', {
      'path': path,
      'outPath': outPath,
      'targetLufs': targetLufs,
    });
  }
}

class MinisBeatResult {
  const MinisBeatResult({required this.bpm, required this.onsetsMs});
  final double bpm;
  final List<int> onsetsMs;
}

class MinisAudioAnalysis {
  static Future<MinisBeatResult> detectBeats(String path) async {
    final res = await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>(
      'detectBeats',
      {'path': path},
    );
    final bpm = (res?['bpm'] as num?)?.toDouble() ?? 0.0;
    final onsets = (res?['onsetsMs'] as List?)
            ?.whereType<num>()
            .map((n) => n.toInt())
            .toList(growable: false) ??
        const <int>[];
    return MinisBeatResult(bpm: bpm, onsetsMs: onsets);
  }
}

class MinisAudioPitch {
  static Future<void> pitchShift({
    required String path,
    required double semitones,
    required String outPath,
  }) async {
    await minisAudioChannel.invokeMethod('pitchShift', {
      'path': path,
      'semitones': semitones,
      'outPath': outPath,
    });
  }

  static Future<void> timeStretch({
    required String path,
    required double factor,
    required String outPath,
    bool keepPitch = true,
  }) async {
    await minisAudioChannel.invokeMethod('timeStretch', {
      'path': path,
      'factor': factor,
      'outPath': outPath,
      'keepPitch': keepPitch,
    });
  }
}
