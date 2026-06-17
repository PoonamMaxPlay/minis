import 'dart:async';

import 'package:flutter/foundation.dart';

import 'minis_audio_channel.dart';

/// API-compatible subset of `audio_waveforms` `PlayerState`.
enum PlayerState {
  stopped,
  initialised,
  paused,
  playing,
}

extension PlayerStateChecks on PlayerState {
  bool get isPlaying => this == PlayerState.playing;
  bool get isPaused => this == PlayerState.paused;
  bool get isStopped => this == PlayerState.stopped;
  bool get isInitialised =>
      this == PlayerState.initialised ||
      this == PlayerState.paused ||
      this == PlayerState.playing;
}

enum FinishMode { loop, pause, stop }

PlayerState _decodeState(String? raw) {
  switch (raw) {
    case 'playing':
      return PlayerState.playing;
    case 'paused':
      return PlayerState.paused;
    case 'initialised':
      return PlayerState.initialised;
    default:
      return PlayerState.stopped;
  }
}

class _PlayerEventHub {
  _PlayerEventHub._() {
    minisAudioPlayerEvents.receiveBroadcastStream().listen(
      (raw) {
        if (raw is! Map) return;
        final id = (raw['playerId'] as num?)?.toInt();
        if (id == null) return;
        _broadcast(id, raw);
      },
      onError: (_) {},
    );
  }
  static final _PlayerEventHub instance = _PlayerEventHub._();

  final Map<int, List<void Function(Map<dynamic, dynamic>)>> _subs = {};

  void register(int id, void Function(Map<dynamic, dynamic>) cb) {
    (_subs[id] ??= []).add(cb);
  }

  void unregister(int id, void Function(Map<dynamic, dynamic>) cb) {
    final list = _subs[id];
    if (list == null) return;
    list.remove(cb);
    if (list.isEmpty) _subs.remove(id);
  }

  void _broadcast(int id, Map<dynamic, dynamic> ev) {
    final list = _subs[id];
    if (list == null) return;
    for (final cb in List.of(list)) {
      try {
        cb(ev);
      } catch (_) {}
    }
  }
}

/// Drop-in replacement for `audio_waveforms` `PlayerController` covering the
/// subset of methods used by Minis (prepare/start/pause/stop/seek/finish/dispose,
/// position + completion + state streams).
class PlayerController {
  PlayerController();

  int? _playerId;
  PlayerState _state = PlayerState.stopped;
  int _maxDuration = 0;
  bool _disposed = false;

  bool overrideAudioSession = false;

  final StreamController<int> _positionCtrl = StreamController<int>.broadcast();
  final StreamController<void> _completionCtrl =
      StreamController<void>.broadcast();
  final StreamController<PlayerState> _stateCtrl =
      StreamController<PlayerState>.broadcast();

  void Function(Map<dynamic, dynamic>)? _eventHandler;

  Stream<int> get onCurrentDurationChanged => _positionCtrl.stream;
  Stream<void> get onCompletion => _completionCtrl.stream;
  Stream<PlayerState> get onPlayerStateChanged => _stateCtrl.stream;

  PlayerState get playerState => _state;
  int get maxDuration => _maxDuration;

  Future<void> preparePlayer({
    required String path,
    bool shouldExtractWaveform = false,
    double volume = 1.0,
  }) async {
    if (_disposed) return;
    final res =
        await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>('playerCreate', {
      'path': path,
      'volume': volume,
      'overrideSession': overrideAudioSession,
      'existingId': _playerId,
    });
    if (res == null) {
      throw StateError('Failed to prepare player for $path');
    }
    final id = (res['playerId'] as num).toInt();
    _maxDuration = (res['durationMs'] as num?)?.toInt() ?? 0;
    _bindId(id);
    _updateState(PlayerState.initialised);
  }

  Future<void> setFinishMode({required FinishMode finishMode}) async {
    final id = _playerId;
    if (id == null) return;
    await minisAudioChannel.invokeMethod('playerSetFinishMode', {
      'playerId': id,
      'mode': finishMode.name,
    });
  }

  Future<void> startPlayer() async {
    final id = _playerId;
    if (id == null) return;
    await minisAudioChannel.invokeMethod('playerControl', {
      'playerId': id,
      'op': 'play',
    });
  }

  Future<void> pausePlayer() async {
    final id = _playerId;
    if (id == null) return;
    await minisAudioChannel.invokeMethod('playerControl', {
      'playerId': id,
      'op': 'pause',
    });
  }

  Future<void> stopPlayer() async {
    final id = _playerId;
    if (id == null) return;
    await minisAudioChannel.invokeMethod('playerControl', {
      'playerId': id,
      'op': 'stop',
    });
  }

  Future<void> seekTo(int ms) async {
    final id = _playerId;
    if (id == null) return;
    await minisAudioChannel.invokeMethod('playerControl', {
      'playerId': id,
      'op': 'seek',
      'value': ms,
    });
  }

  Future<void> setVolume(double volume) async {
    final id = _playerId;
    if (id == null) return;
    await minisAudioChannel.invokeMethod('playerControl', {
      'playerId': id,
      'op': 'volume',
      'value': volume,
    });
  }

  Future<int> getDuration() async {
    final id = _playerId;
    if (id == null) return _maxDuration;
    final res = await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>(
      'playerGetDuration',
      {'playerId': id},
    );
    final d = (res?['durationMs'] as num?)?.toInt() ?? 0;
    if (d > 0) _maxDuration = d;
    return _maxDuration;
  }

  Future<void> release() async {
    final id = _playerId;
    if (id == null) return;
    try {
      await minisAudioChannel.invokeMethod('playerDispose', {'playerId': id});
    } catch (_) {}
    _detachId();
    _updateState(PlayerState.stopped);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_playerId != null) {
      final id = _playerId!;
      _detachId();
      minisAudioChannel.invokeMethod('playerDispose', {'playerId': id}).catchError(
        (_) {},
      );
    }
    _positionCtrl.close();
    _completionCtrl.close();
    _stateCtrl.close();
  }

  void _bindId(int id) {
    if (_playerId == id) return;
    _detachId();
    _playerId = id;
    void handler(Map<dynamic, dynamic> ev) {
      final type = ev['type'] as String?;
      switch (type) {
        case 'position':
          final pos = (ev['positionMs'] as num?)?.toInt() ?? 0;
          if (!_positionCtrl.isClosed) _positionCtrl.add(pos);
          break;
        case 'completed':
          if (!_completionCtrl.isClosed) _completionCtrl.add(null);
          _updateState(PlayerState.paused);
          break;
        case 'state':
          _updateState(_decodeState(ev['state'] as String?));
          break;
        case 'duration':
          final d = (ev['durationMs'] as num?)?.toInt() ?? 0;
          if (d > 0) _maxDuration = d;
          break;
      }
    }
    _eventHandler = handler;
    _PlayerEventHub.instance.register(id, handler);
  }

  void _detachId() {
    final id = _playerId;
    final h = _eventHandler;
    if (id != null && h != null) {
      _PlayerEventHub.instance.unregister(id, h);
    }
    _playerId = null;
    _eventHandler = null;
  }

  void _updateState(PlayerState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }
}

/// Pure-Dart fallback used on platforms where the native channel isn't wired
/// (web, desktop). All methods are no-ops; state stays stopped.
@visibleForTesting
PlayerController buildPlayerControllerForTests() => PlayerController();
