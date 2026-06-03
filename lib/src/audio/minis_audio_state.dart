import 'dart:async';

import 'package:flutter/services.dart';

const EventChannel _stateChannel = EventChannel('loopit/minis/audio/state');
const EventChannel _progressChannel = EventChannel('loopit/minis/audio/progress');

/// Route-change / interruption events from the native audio session.
class MinisAudioStateEvent {
  const MinisAudioStateEvent({required this.type, required this.payload});
  final String type;
  final Map<String, dynamic> payload;
}

class MinisAudioStateStream {
  MinisAudioStateStream._();
  static final instance = MinisAudioStateStream._();

  Stream<MinisAudioStateEvent>? _cached;

  Stream<MinisAudioStateEvent> stream() {
    _cached ??= _stateChannel.receiveBroadcastStream().map((raw) {
      if (raw is Map) {
        return MinisAudioStateEvent(
          type: (raw['type'] as String?) ?? 'unknown',
          payload: Map<String, dynamic>.from(raw),
        );
      }
      return const MinisAudioStateEvent(type: 'unknown', payload: {});
    }).asBroadcastStream();
    return _cached!;
  }
}

/// Progress (0..1) for long-running ops: mix, normalize, pitch, stretch.
class MinisAudioProgress {
  const MinisAudioProgress({required this.taskId, required this.pct});
  final String taskId;
  final double pct;
}

class MinisAudioProgressStream {
  MinisAudioProgressStream._();
  static final instance = MinisAudioProgressStream._();

  Stream<MinisAudioProgress>? _cached;

  Stream<MinisAudioProgress> stream() {
    _cached ??= _progressChannel.receiveBroadcastStream().map((raw) {
      if (raw is Map) {
        return MinisAudioProgress(
          taskId: (raw['taskId'] as String?) ?? '',
          pct: (raw['pct'] as num?)?.toDouble() ?? 0.0,
        );
      }
      return const MinisAudioProgress(taskId: '', pct: 0);
    }).asBroadcastStream();
    return _cached!;
  }
}

