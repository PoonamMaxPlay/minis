import 'dart:async';
import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum NativePlayerEventKind { ready, playing, paused, completed, buffering, error }

class NativePlayerEvent {
  final NativePlayerEventKind kind;
  final int posMs;
  final int bufMs;
  final String? error;
  const NativePlayerEvent({required this.kind, this.posMs = 0, this.bufMs = 0, this.error});

  factory NativePlayerEvent.fromMap(Map<Object?, Object?> m) {
    final kindStr = (m['kind'] as String?) ?? 'ready';
    NativePlayerEventKind k;
    switch (kindStr) {
      case 'playing': k = NativePlayerEventKind.playing; break;
      case 'paused': k = NativePlayerEventKind.paused; break;
      case 'completed': k = NativePlayerEventKind.completed; break;
      case 'buffering': k = NativePlayerEventKind.buffering; break;
      case 'error': k = NativePlayerEventKind.error; break;
      default: k = NativePlayerEventKind.ready;
    }
    return NativePlayerEvent(
      kind: k,
      posMs: (m['posMs'] as num?)?.toInt() ?? 0,
      bufMs: (m['bufMs'] as num?)?.toInt() ?? 0,
      error: m['err'] as String?,
    );
  }
}

class NativePlayerValue {
  final bool isInitialized;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Size size;
  final int rotationCorrection;
  final bool hasError;
  final String? errorMessage;
  const NativePlayerValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.size = Size.zero,
    this.rotationCorrection = 0,
    this.hasError = false,
    this.errorMessage,
  });

  double get aspectRatio {
    if (size.width <= 0 || size.height <= 0) return 1.0;
    return size.width / size.height;
  }

  String? get errorDescription => errorMessage;

  NativePlayerValue copyWith({
    bool? isInitialized,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Size? size,
    int? rotationCorrection,
    bool? hasError,
    String? errorMessage,
  }) => NativePlayerValue(
        isInitialized: isInitialized ?? this.isInitialized,
        isPlaying: isPlaying ?? this.isPlaying,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        size: size ?? this.size,
        rotationCorrection: rotationCorrection ?? this.rotationCorrection,
        hasError: hasError ?? this.hasError,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

class VideoPlayerOptions {
  final bool mixWithOthers;
  final bool allowBackgroundPlayback;
  const VideoPlayerOptions({this.mixWithOthers = false, this.allowBackgroundPlayback = false});
}

class NativeVideoPlayerController extends ChangeNotifier
    implements ValueListenable<NativePlayerValue> {
  static const _methodCh = MethodChannel('loopit/minis/player');
  static const _eventPrefix = 'loopit/minis/player/events/';

  NativeVideoPlayerController();
  NativeVideoPlayerController.file(File file, {VideoPlayerOptions? videoPlayerOptions})
      : _initialPath = file.path;
  NativeVideoPlayerController.network(String url, {VideoPlayerOptions? videoPlayerOptions})
      : _initialPath = url;

  String? _initialPath;
  String? _playerId;
  int durationMs = 0;
  int width = 0;
  int height = 0;
  EventChannel? _evCh;
  StreamSubscription<dynamic>? _evSub;
  final StreamController<NativePlayerEvent> _events = StreamController.broadcast();
  final Completer<void> _readyCompleter = Completer<void>();
  Timer? _posPump;
  bool _loop = false;
  NativePlayerValue _value = const NativePlayerValue();

  String? get playerId => _playerId;
  Stream<NativePlayerEvent> get events => _events.stream;
  Future<void> get ready => _readyCompleter.future;
  @override
  NativePlayerValue get value => _value;

  Future<void> initialize() async {
    if (_initialPath == null) throw StateError('controller has no path; use open()');
    await open(path: _initialPath!);
  }

  Future<void> open({
    required String path,
    bool loop = false,
    bool autoplay = false,
    bool mute = false,
  }) async {
    _loop = loop;
    final r = await _methodCh.invokeMapMethod<String, Object?>('create', {
      'path': path, 'loop': loop, 'autoplay': autoplay, 'mute': mute,
    });
    if (r == null) throw StateError('player create returned null');
    _playerId = r['playerId'] as String?;
    durationMs = (r['durationMs'] as num?)?.toInt() ?? 0;
    width = (r['w'] as num?)?.toInt() ?? 0;
    height = (r['h'] as num?)?.toInt() ?? 0;
    _value = _value.copyWith(
      isInitialized: true,
      duration: Duration(milliseconds: durationMs),
      size: Size(width.toDouble(), height.toDouble()),
      isPlaying: autoplay,
    );
    notifyListeners();
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    if (_playerId != null) {
      _evCh = EventChannel('$_eventPrefix$_playerId');
      _evSub = _evCh!.receiveBroadcastStream().listen((raw) {
        if (raw is Map) {
          final ev = NativePlayerEvent.fromMap(raw.cast<Object?, Object?>());
          _onEvent(ev);
          _events.add(ev);
        }
      });
      _posPump = Timer.periodic(const Duration(milliseconds: 80), (_) {
        if (_value.isPlaying) {
          _value = _value.copyWith(
            position: _value.position + const Duration(milliseconds: 80),
          );
          notifyListeners();
        }
      });
    }
  }

  void _onEvent(NativePlayerEvent ev) {
    switch (ev.kind) {
      case NativePlayerEventKind.ready:
        if (!_readyCompleter.isCompleted) _readyCompleter.complete();
        break;
      case NativePlayerEventKind.playing:
        _value = _value.copyWith(isPlaying: true, position: Duration(milliseconds: ev.posMs));
        notifyListeners();
        break;
      case NativePlayerEventKind.paused:
        _value = _value.copyWith(isPlaying: false, position: Duration(milliseconds: ev.posMs));
        notifyListeners();
        break;
      case NativePlayerEventKind.completed:
        if (_loop) {
          _value = _value.copyWith(position: Duration.zero, isPlaying: true);
        } else {
          _value = _value.copyWith(isPlaying: false, position: _value.duration);
        }
        notifyListeners();
        break;
      case NativePlayerEventKind.buffering:
        break;
      case NativePlayerEventKind.error:
        _value = _value.copyWith(hasError: true, errorMessage: ev.error, isPlaying: false);
        notifyListeners();
        break;
    }
  }

  Future<void> play() async {
    await _send('play');
    _value = _value.copyWith(isPlaying: true);
    notifyListeners();
  }
  Future<void> pause() async {
    await _send('pause');
    _value = _value.copyWith(isPlaying: false);
    notifyListeners();
  }
  Future<void> seek(int ms) => seekTo(Duration(milliseconds: ms));
  Future<void> seekTo(Duration d) async {
    await _send('seek', {'ms': d.inMilliseconds});
    _value = _value.copyWith(position: d);
    notifyListeners();
  }
  Future<void> setVolume(double v) => _send('volume', {'value': v});
  Future<void> setRate(double v) => _send('rate', {'value': v});
  Future<void> setPlaybackSpeed(double v) => setRate(v);

  Future<void> setLooping(bool loop) async {
    _loop = loop;
  }

  @override
  Future<void> dispose() async {
    final id = _playerId;
    _playerId = null;
    _posPump?.cancel();
    _posPump = null;
    await _evSub?.cancel();
    _evSub = null;
    _evCh = null;
    if (id != null) {
      await _methodCh.invokeMethod('dispose', {'playerId': id});
    }
    await _events.close();
    super.dispose();
  }

  Future<void> _send(String method, [Map<String, Object?>? extra]) async {
    final id = _playerId;
    if (id == null) return;
    final args = <String, Object?>{'playerId': id, ...?extra};
    await _methodCh.invokeMethod(method, args);
  }
}

class NativeVideoPlayerView extends StatelessWidget {
  final NativeVideoPlayerController controller;
  final String fit;
  final bool hdrTonemap;
  const NativeVideoPlayerView({
    super.key,
    required this.controller,
    this.fit = 'contain',
    this.hdrTonemap = true,
  });

  @override
  Widget build(BuildContext context) {
    final id = controller.playerId;
    if (id == null) return const SizedBox.shrink();
    const viewType = 'loopit/minis/player';
    final params = <String, dynamic>{'playerId': id, 'fit': fit, 'hdrTonemap': hdrTonemap};
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        viewType: viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return const SizedBox.shrink();
  }
}
