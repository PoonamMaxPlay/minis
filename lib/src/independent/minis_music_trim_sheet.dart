import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:loopit_minis/src/audio/minis_audio_player.dart';
import 'package:loopit_minis/src/sys/paths.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:loopit_minis/src/independent/minis_music_segment.dart';
import 'package:loopit_minis/src/independent/minis_music_trim_math.dart';
import 'package:loopit_minis/src/minis_user_message.dart';

/// Pick start time for a slice of [audioPath] up to [sessionCapMs] long (reel cap).
///
/// [initialStartMs] restores scroll when the user re-opens trim for the same file
/// (LoopIt-style). Must be `null` on first pick.
///
/// UI and playback follow the same pattern as LoopIt **SelectedMusicSheet** /
/// **WaveSlider** (horizontal scroll + selection window + [audio_waveforms]).
/// On platforms without the plugin (e.g. macOS), shows a short notice and
/// returns a default segment (full cap from offset 0).
Future<MinisMusicSegment?> showMinisMusicTimingSheet(
  BuildContext context, {
  required String audioPath,
  required int sessionCapMs,
  int? initialStartMs,
}) async {
  if (!minisAudioWaveformsTrimSupported()) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'Audio trim works on iOS and Android. Using your track from the start.',
        ),
      ),
    );
    return MinisMusicSegment(
      path: audioPath,
      startMs: 0,
      endMs: math.max(1, sessionCapMs),
    );
  }

  return showModalBottomSheet<MinisMusicSegment>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final h = (MediaQuery.sizeOf(ctx).height * 0.58).clamp(360.0, 560.0);
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(ctx).bottom + 8),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: h,
            child: _MinisLoopStyleMusicSheet(
              audioPath: audioPath,
              sessionCapMs: sessionCapMs,
              initialStartMs: initialStartMs,
            ),
          ),
        ),
      );
    },
  );
}

/// LoopIt-style sheet: scrollable faux waveform, fixed window, play/pause.
class _MinisLoopStyleMusicSheet extends StatefulWidget {
  const _MinisLoopStyleMusicSheet({
    required this.audioPath,
    required this.sessionCapMs,
    this.initialStartMs,
  });

  final String audioPath;
  final int sessionCapMs;

  /// When re-opening trim (LoopIt-style), scroll to this start (ms, clamped).
  final int? initialStartMs;

  @override
  State<_MinisLoopStyleMusicSheet> createState() =>
      _MinisLoopStyleMusicSheetState();
}

class _MinisLoopStyleMusicSheetState extends State<_MinisLoopStyleMusicSheet> {
  static const double _borderWidth = 10;
  static const double _barWidth = 2;
  static const double _barHorizontalMargin = 1;
  // Wider than before so the selection frame is clearly visible like LoopIt.
  static const double _barInBoxCount = 70;

  final PlayerController _audioPlayer = PlayerController();
  final ScrollController _scrollController = ScrollController();

  bool _loading = true;
  String? _error;
  int? _durationMs;
  int _audioStartMs = 0;
  bool _isPlaying = false;
  bool _startingPlayback = false;
  double _currentProgress = 0;
  double _oneBarValue = 1;
  int _waveBarCount = 1;
  String? _playbackPath;

  /// Avoid scroll-driven preview when calling [ScrollController.jumpTo].
  bool _suppressScrollCallback = false;

  Timer? _previewCapTimer;
  StreamSubscription<int>? _positionSub;
  StreamSubscription<void>? _completionSub;
  Timer? _scrollDebounce;

  double get _barTotalWidth => _barWidth + (_barHorizontalMargin * 2);
  double get _boxWidth => _barTotalWidth * _barInBoxCount;

  int get _windowMs {
    final d = _durationMs;
    if (d == null || d <= 0) return math.max(1, widget.sessionCapMs);
    return math.min(widget.sessionCapMs, d);
  }

  @override
  void initState() {
    super.initState();
    _audioPlayer.overrideAudioSession = true;
    _scrollController.addListener(_onScrollChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(_initPlayer()));
  }

  static Future<String?> _normalisedPath(String raw) async {
    try {
      final f = File(raw);
      if (await f.exists()) {
        return f.absolute.path.replaceAll('\\', '/');
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> _copyToTemp(String raw) async {
    try {
      final src = File(raw);
      if (!await src.exists()) return null;
      final dirPath = await NativePaths.cacheDir();
      if (dirPath == null) return null;
      final ext = NativePaths.extension(raw);
      final dest = File(
        NativePaths.join([
          dirPath,
          'minis_music_${DateTime.now().microsecondsSinceEpoch}$ext',
        ]),
      );
      await src.copy(dest.path);
      return dest.absolute.path.replaceAll('\\', '/');
    } catch (_) {
      return null;
    }
  }

  Future<int> _readDurationWithRetry([int attempts = 5]) async {
    var duration = _audioPlayer.maxDuration;
    for (var i = 0; i < attempts; i++) {
      if (duration > 0) return duration;
      try {
        duration = await _audioPlayer.getDuration();
      } catch (e) {
        debugPrint('minis_music_trim: getDuration failed: $e');
        duration = 0;
      }
      if (duration > 0) return duration;
      if (i < attempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return duration;
  }

  Future<void> _playerCall(
    Future<void> Function() action, {
    String step = 'player-call',
    int timeoutMs = 2200,
  }) async {
    await action().timeout(
      Duration(milliseconds: timeoutMs),
      onTimeout: () => throw TimeoutException('timeout at $step'),
    );
  }

  void _logTrim(String message) {
    debugPrint('MINIS_TRIM_AUDIO: $message');
  }

  Future<bool> _waitForPlayingState([int timeoutMs = 450]) async {
    if (_audioPlayer.playerState.isPlaying) return true;
    try {
      await _audioPlayer.onPlayerStateChanged
          .firstWhere((s) => s.isPlaying)
          .timeout(Duration(milliseconds: timeoutMs));
      return true;
    } catch (_) {
      return _audioPlayer.playerState.isPlaying;
    }
  }

  Future<void> _initPlayer() async {
    var path = await _normalisedPath(widget.audioPath);
    path ??= await _copyToTemp(widget.audioPath);
    if (!mounted) return;
    if (path == null) {
      _logTrim('init failed: could not resolve audio path');
      setState(() {
        _loading = false;
        _error = 'Could not access the audio file.';
      });
      return;
    }

    Future<bool> prepare(String pth) async {
      try {
        await _audioPlayer.preparePlayer(
          path: pth,
          shouldExtractWaveform: false,
          volume: 1.0,
        );
      } catch (e) {
        debugPrint('minis_music_trim: preparePlayer failed: $e');
        return false;
      }
      if (!mounted) return false;
      return _audioPlayer.playerState.isInitialised;
    }

    var ok = await prepare(path);
    if (!ok) {
      final alt = await _copyToTemp(widget.audioPath);
      if (alt != null && alt != path) {
        path = alt;
        ok = await prepare(path);
      }
    }
    if (!mounted) return;
    if (!ok) {
      _logTrim('init failed: preparePlayer did not initialize for path=$path');
      setState(() {
        _loading = false;
        _error = 'Could not open this file for playback.';
      });
      return;
    }

    _playbackPath = path;

    var d = await _readDurationWithRetry();
    if (!mounted) return;
    if (d <= 0) {
      _logTrim('init failed: duration<=0 for path=$path');
      setState(() {
        _loading = false;
        _error = 'Could not read audio duration.';
      });
      return;
    }

    final window = math.min(widget.sessionCapMs, d);
    final windowSec = math.max(1, window / 1000.0);
    _oneBarValue = _barInBoxCount / windowSec;
    _waveBarCount = math.max(
      1,
      (_oneBarValue * (d / 1000)).ceil(),
    );

    if (!mounted) return;
    setState(() {
      _durationMs = d;
      _loading = false;
      _audioStartMs = 0;
      _currentProgress = 0;
    });
    _logTrim(
        'init ok: path=$path durationMs=$d windowMs=$_windowMs bars=$_waveBarCount');

    try {
      await _audioPlayer.setFinishMode(finishMode: FinishMode.pause);
      await _audioPlayer.seekTo(0);
    } catch (e) {
      debugPrint('minis_music_trim: seekTo(0) failed: $e');
    }

    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyInitialScrollAndPreview();
    });
  }

  int get _maxStartMsValue {
    final d = _durationMs;
    if (d == null || d <= 0) return 0;
    return math.max(0, d - _windowMs);
  }

  double _innerTrackWidth() {
    final d = _durationMs;
    if (d == null || d <= 0) return _boxWidth;
    return minisMusicTrimInnerTrackWidthPx(
      boxWidthPx: _boxWidth,
      waveBarCount: _waveBarCount,
      barTotalWidth: _barTotalWidth,
    );
  }

  double _maxScrollPx(double viewportWidth) {
    return minisMusicTrimMaxScrollForViewport(
      viewportWidthPx: viewportWidth,
      boxWidthPx: _boxWidth,
      innerTrackWidthPx: _innerTrackWidth(),
    );
  }

  void _applyInitialScrollAndPreview() {
    void apply([int attempt = 0]) {
      if (!mounted || attempt > 10) return;
      final dNow = _durationMs;
      if (dNow == null || dNow <= 0) return;
      if (!_scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) => apply(attempt + 1));
        return;
      }
      final sw = MediaQuery.sizeOf(context).width;
      final maxOff = _maxScrollPx(sw);
      _suppressScrollCallback = true;
      final initial = widget.initialStartMs;
      final maxStart = _maxStartMsValue;
      final off = initial != null && maxStart > 0
          ? minisMusicTrimScrollOffsetForStartMsLinear(
              startMs: initial.clamp(0, maxStart),
              maxScrollPx: maxOff,
              maxStartMs: maxStart,
            )
          : 0.0;
      _scrollController.jumpTo(off.clamp(0.0, maxOff));
      _suppressScrollCallback = false;
      _syncStartMsFromScrollOffset();
    }

    apply();
  }

  void _syncStartMsFromScrollOffset() {
    final d = _durationMs;
    if (d == null || d <= 0 || !mounted) return;
    final sw = MediaQuery.sizeOf(context).width;
    final maxOff = _maxScrollPx(sw);
    final raw = _scrollController.hasClients ? _scrollController.offset : 0.0;
    final off = raw.clamp(0.0, maxOff);
    final start = minisMusicTrimStartMsFromScrollLinear(
      scrollOffsetPx: off,
      maxScrollPx: maxOff,
      maxStartMs: _maxStartMsValue,
    );
    if (start != _audioStartMs) {
      setState(() => _audioStartMs = start);
    }
  }

  void _clampScrollToValidRange() {
    if (!mounted || !_scrollController.hasClients) return;
    final maxOff = _maxScrollPx(MediaQuery.sizeOf(context).width);
    if (_scrollController.offset <= maxOff) return;
    _suppressScrollCallback = true;
    _scrollController.jumpTo(maxOff);
    _suppressScrollCallback = false;
  }

  void _onScrollChanged() {
    if (_suppressScrollCallback || _loading || !mounted) return;
    final d = _durationMs;
    if (d == null || d <= 0) return;

    _clampScrollToValidRange();

    final sw = MediaQuery.sizeOf(context).width;
    final maxOff = _maxScrollPx(sw);
    final off = _scrollController.offset.clamp(0.0, maxOff);
    final start = minisMusicTrimStartMsFromScrollLinear(
      scrollOffsetPx: off,
      maxScrollPx: maxOff,
      maxStartMs: _maxStartMsValue,
    );

    // Update start time immediately while dragging (LoopIt shows live feedback;
    // we previously only updated after debounce, which felt "stuck").
    setState(() {
      _currentProgress = 0;
      _audioStartMs = start;
    });

    if (_isPlaying) {
      unawaited(_onPause());
    }

    // Debounce only auto-preview, like LoopIt DebounceAction on onPlayAudio.
    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(const Duration(milliseconds: 150), () async {
      if (!mounted || !_scrollController.hasClients) return;
      _clampScrollToValidRange();
      await _onPlayAudio();
    });
  }

  void _listenPlayer() {
    _positionSub?.cancel();
    final window = _windowMs;
    _positionSub = _audioPlayer.onCurrentDurationChanged.listen((eventMs) {
      final rel = (eventMs - _audioStartMs + 100).clamp(0, window);
      if (mounted) {
        setState(() => _currentProgress = rel / window);
      }
    });
    _completionSub?.cancel();
    _completionSub = _audioPlayer.onCompletion.listen((_) {
      if (mounted) {
        setState(() {
          _currentProgress = 1;
          _isPlaying = false;
        });
      }
    });
  }

  Future<void> _onPlayAudio() async {
    if (_startingPlayback) {
      _logTrim('play ignored: start already in progress');
      return;
    }
    _startingPlayback = true;
    final path = _playbackPath;
    final d = _durationMs;
    if (path == null || d == null || d <= 0) {
      _startingPlayback = false;
      return;
    }
    if (!mounted) {
      _startingPlayback = false;
      return;
    }
    _logTrim(
        'play requested: playerState=${_audioPlayer.playerState} startMs=$_audioStartMs durationMs=$d');

    var duration = d;
    final refreshedDuration = await _readDurationWithRetry(3);
    if (refreshedDuration > 0) {
      duration = refreshedDuration;
      if (mounted && duration != _durationMs) {
        setState(() => _durationMs = duration);
      }
      _logTrim('duration refreshed: durationMs=$duration');
    }

    _listenPlayer();
    try {
      final safeStartMs =
          _audioStartMs.clamp(0, math.max(0, duration - 1)).toInt();
      if (safeStartMs != _audioStartMs && mounted) {
        setState(() => _audioStartMs = safeStartMs);
      }
      final stateBeforePlay = _audioPlayer.playerState;
      final shouldPrepare = stateBeforePlay.isStopped ||
          (!stateBeforePlay.isInitialised && !stateBeforePlay.isPaused);
      if (shouldPrepare) {
        _logTrim(
            'prepare before play: state=${_audioPlayer.playerState} path=$path');
        await _playerCall(
          () => _audioPlayer.preparePlayer(
            path: path,
            shouldExtractWaveform: false,
            volume: 1.0,
          ),
          step: 'prepare-before-play',
        );
        _logTrim('prepare done: state=${_audioPlayer.playerState}');
      }
      if (_audioPlayer.playerState.isPlaying) {
        _logTrim('pause existing playback before restart');
        await _playerCall(
          () => _audioPlayer.pausePlayer(),
          step: 'pause-before-restart',
        );
      }
      // `setFinishMode` is already configured during init/prepare; calling it
      // per-play can hang on some devices.
      await _playerCall(
        () => _audioPlayer.seekTo(safeStartMs),
        step: 'seek',
      );
      _logTrim(
          'seek done: safeStartMs=$safeStartMs state=${_audioPlayer.playerState}');
      await _playerCall(
        () => _audioPlayer.startPlayer(),
        step: 'start',
      );
      _logTrim('start called: state=${_audioPlayer.playerState}');
      if (!await _waitForPlayingState()) {
        _logTrim('start not playing, retrying hard prepare');
        // One hard retry for devices where initial start remains silent.
        await _playerCall(
          () => _audioPlayer.preparePlayer(
            path: path,
            shouldExtractWaveform: false,
            volume: 1.0,
          ),
          step: 'hard-prepare',
        );
        await _playerCall(
          () => _audioPlayer.seekTo(safeStartMs),
          step: 'hard-seek',
        );
        await _playerCall(
          () => _audioPlayer.startPlayer(),
          step: 'hard-start',
        );
        _logTrim('hard retry start called: state=${_audioPlayer.playerState}');
      }
      if (!await _waitForPlayingState(300)) {
        _logTrim('play failed: still not in playing state');
        throw 'Player did not enter playing state';
      }

      var previewMs = duration - safeStartMs;
      final window = _windowMs;
      if (window < previewMs) {
        previewMs = window;
      }
      previewMs = math.max(1, previewMs);

      if (!mounted) return;
      setState(() => _isPlaying = true);
      _logTrim(
          'play success: previewMs=$previewMs state=${_audioPlayer.playerState}');

      _previewCapTimer?.cancel();
      _previewCapTimer = Timer(Duration(milliseconds: previewMs), () {
        unawaited(_onPause());
      });
    } catch (e) {
      _logTrim('play exception: $e state=${_audioPlayer.playerState}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(minisUserFriendlyException(e, context: 'audio')),
          ),
        );
      }
    } finally {
      _startingPlayback = false;
    }
  }

  Future<void> _onPause() async {
    _previewCapTimer?.cancel();
    _previewCapTimer = null;
    try {
      await _audioPlayer.pausePlayer();
    } catch (_) {}
    await _positionSub?.cancel();
    _positionSub = null;
    await _completionSub?.cancel();
    _completionSub = null;
    if (mounted) setState(() => _isPlaying = false);
  }

  Future<void> _playPause() async {
    if (_isPlaying) {
      await _onPause();
    } else {
      await _onPlayAudio();
    }
  }

  void _onContinue() {
    final d = _durationMs;
    final segmentPath = _playbackPath ?? widget.audioPath;
    if (d == null || d <= 0) {
      Navigator.of(context).pop(
        MinisMusicSegment(
          path: segmentPath,
          startMs: 0,
          endMs: math.max(1, widget.sessionCapMs),
        ),
      );
      return;
    }

    _syncStartMsFromScrollOffset();
    _clampScrollToValidRange();

    final window = _windowMs;
    var start = _audioStartMs;
    if (d > window && (d - start) < window) {
      final trimmedDuration = d - start;
      if (trimmedDuration < window) {
        final missing = window - trimmedDuration;
        start -= missing;
        if (start < 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Move the selection — not enough audio left.'),
            ),
          );
          return;
        }
      }
    }

    final end = math.min(start + window, d);
    unawaited(_onPause());
    Navigator.of(context).pop(
      MinisMusicSegment(
        path: segmentPath,
        startMs: start,
        endMs: end,
      ),
    );
  }

  String _fmtMs(int ms) {
    final s = (ms / 1000).floor();
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _scrollDebounce?.cancel();
    _previewCapTimer?.cancel();
    _positionSub?.cancel();
    _completionSub?.cancel();
    _scrollController.removeListener(_onScrollChanged);
    _scrollController.dispose();
    unawaited(
      _audioPlayer.pausePlayer().catchError((_) {}).then((_) {
        _audioPlayer.release().catchError((_) {});
      }),
    );
    _audioPlayer.dispose();
    // Clean up the temp audio copy if one was created.
    final tempPath = _playbackPath;
    if (tempPath != null && tempPath != widget.audioPath) {
      File(tempPath).delete().catchError((_) => File(tempPath));
    }
    super.dispose();
  }

  String get _trackDisplayName {
    final n = NativePaths.basename(widget.audioPath);
    if (n.isEmpty) return 'Selected audio';
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noScrollNeeded = !_loading &&
        _error == null &&
        _maxStartMsValue == 0 &&
        _durationMs != null;

    return Material(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      color: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      'Select music',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () {
                    unawaited(_onPause());
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              _trackDisplayName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
          if (!_loading && _error == null && _durationMs != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
              child: Text(
                'Full track ${_fmtMs(_durationMs!)} · '
                '${_fmtMs(_windowMs)} selection',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Drag the full waveform; the purple band is your time limit. '
                  'The start time (above) moves as you scroll. Tap play to preview.',
                  style: theme.textTheme.bodySmall,
                ),
                if (noScrollNeeded) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This track fits entirely in your cap — start stays at 00:00.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 200),
                            opacity: _isPlaying ? 0 : 1,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    _fmtMs(_audioStartMs),
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          // [Positioned.fill] + [LayoutBuilder]: horizontal scroll must
                          // fill the band so drags register; gradient is [IgnorePointer]
                          // so it never steals hits.
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final bandW = constraints.maxWidth;
                              final pad =
                                  math.max(0.0, bandW / 2 - _boxWidth / 2);
                              return SizedBox(
                                height: 56,
                                width: bandW,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Center(
                                      child: IgnorePointer(
                                        child: Stack(
                                          alignment:
                                              AlignmentDirectional.centerStart,
                                          children: [
                                            Container(
                                              width: _boxWidth,
                                              height: 50,
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                gradient: const LinearGradient(
                                                  colors: [
                                                    Color(0xFF9333EA),
                                                    Color(0xFFEC4899),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            SizedBox(
                                              width: _boxWidth,
                                              height: 50,
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                  _borderWidth / 2,
                                                ),
                                                child: ColoredBox(
                                                  color:
                                                      theme.colorScheme.surface,
                                                  child: Align(
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child: AnimatedContainer(
                                                      duration: Duration(
                                                        milliseconds:
                                                            _currentProgress ==
                                                                    0
                                                                ? 0
                                                                : 120,
                                                      ),
                                                      curve: Curves.easeInOut,
                                                      width: math.max(
                                                        0.0,
                                                        (_boxWidth -
                                                                _borderWidth) *
                                                            (1 -
                                                                _currentProgress),
                                                      ),
                                                      height: 50 - _borderWidth,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    // Keep a visible frame edge even when progress
                                    // mask is mostly white at preview start.
                                    Center(
                                      child: IgnorePointer(
                                        child: Container(
                                          width: _boxWidth,
                                          height: 50,
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            border: Border.all(
                                              color: const Color(0xFFEC4899),
                                              width: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned.fill(
                                      child: SingleChildScrollView(
                                        controller: _scrollController,
                                        primary: false,
                                        dragStartBehavior:
                                            DragStartBehavior.down,
                                        scrollDirection: Axis.horizontal,
                                        physics:
                                            const AlwaysScrollableScrollPhysics(
                                          parent: ClampingScrollPhysics(),
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.start,
                                          children: [
                                            SizedBox(
                                              width: pad,
                                              height: 50,
                                            ),
                                            // LoopIt [WaveSlider]: [ConstrainedBox]
                                            // with minWidth = frame so the row is the
                                            // full faux waveform, not a clipped slice.
                                            ConstrainedBox(
                                              constraints: BoxConstraints(
                                                minWidth: _boxWidth,
                                                minHeight: 50,
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: List.generate(
                                                  _waveBarCount,
                                                  (index) {
                                                    return Container(
                                                      height: index % 2 == 0
                                                          ? 20
                                                          : 12,
                                                      margin: const EdgeInsets
                                                          .symmetric(
                                                        horizontal:
                                                            _barHorizontalMargin,
                                                      ),
                                                      width: _barWidth,
                                                      decoration: BoxDecoration(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(10),
                                                        color: const Color(
                                                          0xFF9CA3AF,
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                            ),
                                            SizedBox(
                                              width: pad,
                                              height: 50,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 20),
                          Center(
                            child: InkWell(
                              onTap: _playPause,
                              child: Container(
                                height: 57,
                                width: 57,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  _isPlaying ? Icons.pause : Icons.play_arrow,
                                  size: 36,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                TextButton(
                  onPressed: () {
                    unawaited(_onPause());
                    Navigator.of(context).pop();
                  },
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: (_loading || _error != null) ? null : _onContinue,
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
