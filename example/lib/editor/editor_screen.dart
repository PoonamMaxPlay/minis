import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

import 'editor_config.dart';
import 'editor_filters.dart';
import 'editor_panels.dart';
import 'editor_state.dart';
import 'editor_timeline.dart';
import 'project_io.dart';

class VideoEditorScreen extends StatefulWidget {
  const VideoEditorScreen({super.key, required this.videoPath});

  final String videoPath;

  @override
  State<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

enum _RootTool { video, audio, text, captions, stickers }

extension _RootToolUi on _RootTool {
  Color get accent {
    switch (this) {
      case _RootTool.video:
        return const Color(0xFF22D3EE);
      case _RootTool.audio:
        return const Color(0xFFA78BFA);
      case _RootTool.text:
        return const Color(0xFFFBBF24);
      case _RootTool.captions:
        return const Color(0xFF34D399);
      case _RootTool.stickers:
        return const Color(0xFFF472B6);
    }
  }
}

class _VideoEditorScreenState extends State<VideoEditorScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late EditorState ed;
  VideoPlayerController? _ctrl;
  List<Uint8List> _thumbs = const [];
  bool _thumbsLoading = false;
  _RootTool? _activeTool;
  Ticker? _posTicker;
  bool _busy = false;
  String? _busyLabel;
  double? _exportPct;
  bool _showOnboarding = false;
  String? _exportTaskId;
  Timer? _autosaveTimer;
  Object? _clipboard;
  bool _savedFlash = false;
  Timer? _savedFlashTimer;
  bool _showShortcuts = false;

  final List<EditorSnapshot> _undo = [];
  final List<EditorSnapshot> _redo = [];

  // ─── Pro shuttle (J/K/L + numeric speed presets) ──────────────────
  static const List<double> _shuttleUpLadder = [1.0, 1.5, 2.0, 4.0, 8.0];
  static const List<double> _shuttleDownLadder = [1.0, 0.5, 0.25, 0.125];
  double _shuttleRate = 1.0;
  bool _shuttleActive = false;

  // ─── Loop-region playback (I / O / [ ) ────────────────────────────
  int? _loopInMs;
  int? _loopOutMs;
  bool _loopEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ed = EditorState(videoPath: widget.videoPath);
    ed.addListener(_onStateChanged);
    unawaited(_init());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _ctrl?.pause();
      unawaited(ProjectIO.save(ed));
    } else if (state == AppLifecycleState.resumed) {
      // Don't auto-resume playback; let user tap play.
    }
  }

  @override
  void didChangeMetrics() {
    // Drop thumb cache on extreme size changes / memory pressure indicator
    // (rotation triggers this; helps avoid stale-decoded images).
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
    _scheduleAutosave();
    _maybeRefetchThumbsForZoom();
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(seconds: 2), () async {
      await ProjectIO.save(ed);
      if (!mounted) return;
      setState(() => _savedFlash = true);
      _savedFlashTimer?.cancel();
      _savedFlashTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _savedFlash = false);
      });
    });
  }

  Future<void> _init() async {
    final c = VideoPlayerController.file(File(ed.videoPath));
    try {
      await c.initialize();
    } catch (e) {
      await c.dispose();
      if (!mounted) return;
      final retry = await _confirm(
        title: 'Could not open video',
        body: 'The file may be missing, corrupt, or use an unsupported '
            'codec.\n\n$e',
        confirmLabel: 'Retry',
      );
      if (retry && mounted) {
        unawaited(_init());
      } else if (mounted) {
        Get.back<void>();
      }
      return;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    await c.setLooping(true);
    final dur = c.value.duration.inMilliseconds;
    ed.totalDurationMs = dur;
    final restored = await ProjectIO.restore(ed);
    if (!restored || ed.clips.isEmpty) {
      ed.clips
        ..clear()
        ..add(ClipSegment(id: 'clip0', inMs: 0, outMs: dur));
    } else {
      // Drop tracks whose files are gone (moved/deleted) so playback
      // doesn't fail silently.
      final droppedAudio = <String>[];
      ed.audios.removeWhere((a) {
        if (a.path.isEmpty) return false; // TTS placeholder
        final exists = File(a.path).existsSync();
        if (!exists) droppedAudio.add(a.label);
        return !exists;
      });
      final droppedStickers = <String>[];
      ed.stickers.removeWhere((s) {
        if (!s.url.startsWith('file://')) return false;
        final path = s.url.replaceFirst('file://', '');
        final exists = File(path).existsSync();
        if (!exists) droppedStickers.add(path);
        return !exists;
      });
      if (droppedAudio.isNotEmpty || droppedStickers.isNotEmpty) {
        _toast(
            'Resumed — skipped ${droppedAudio.length + droppedStickers.length} missing file(s)');
      } else {
        _toast('Resumed previous edit');
      }
    }
    final seenOnboard = await OnboardingPrefs.seen();
    if (mounted && !seenOnboard) {
      setState(() => _showOnboarding = true);
    }
    c.addListener(_onControllerChange);
    setState(() => _ctrl = c);
    await c.play();
    _startPositionTicker();
    unawaited(_loadThumbs(ed.videoPath));
  }

  void _onControllerChange() {
    final c = _ctrl;
    if (c == null) return;
    final playing = c.value.isPlaying;
    if (playing != ed.isPlaying) {
      ed.isPlaying = playing;
      if (mounted) setState(() {});
    }
  }

  void _startPositionTicker() {
    _posTicker?.dispose();
    _posTicker = createTicker((_) {
      final c = _ctrl;
      if (c == null || !c.value.isInitialized) return;
      if (!c.value.isPlaying) return;
      final ms = c.value.position.inMilliseconds;
      // ValueNotifier setter dedupes; no full ChangeNotifier broadcast.
      ed.positionMs = ms;
      // Loop-region wrap: if playhead crossed out-point, jump back to in.
      final loopIn = _loopInMs;
      final loopOut = _loopOutMs;
      if (_loopEnabled && loopIn != null && loopOut != null && loopOut > loopIn && ms >= loopOut) {
        unawaited(c.seekTo(Duration(milliseconds: loopIn)));
      }
    })
      ..start();
  }

  int _thumbsLoadToken = 0;
  final Map<int, List<Uint8List>> _thumbBuckets = {};
  int _thumbActiveBucket = 20;
  Timer? _thumbRefetchTimer;
  double _thumbLastPxPerMs = 0;

  // Quantize zoom → desired thumb count. Aim ~1 thumb per kTrackHeight px so
  // each cell is roughly square; round to 20-step buckets to dampen refetch
  // thrash, then clamp to a sane range.
  int _thumbBucketForZoom(double pxPerMs, int totalMs) {
    if (totalMs <= 0) return 20;
    final pxWidth = pxPerMs * totalMs;
    final n = (pxWidth / kTrackHeight).round();
    final bucket = ((n / 20).round() * 20).clamp(20, 200);
    return bucket;
  }

  Future<void> _loadThumbs(String path, {int? count}) async {
    final bucket = count ?? _thumbBucketForZoom(
      ed.timelinePxPerMs,
      ed.totalDurationMs,
    );
    _thumbActiveBucket = bucket;
    final cached = _thumbBuckets[bucket];
    if (cached != null) {
      if (mounted) setState(() => _thumbs = cached);
      return;
    }
    final myToken = ++_thumbsLoadToken;
    if (mounted) setState(() => _thumbsLoading = true);
    try {
      final t = await MinisVidEdit.instance.thumbnailStrip(
        path: path,
        count: bucket,
        width: 96,
        height: 96,
      );
      if (!mounted || myToken != _thumbsLoadToken) return;
      _thumbBuckets[bucket] = t;
      if (bucket == _thumbActiveBucket) {
        setState(() => _thumbs = t);
      }
    } catch (_) {
      if (mounted && myToken == _thumbsLoadToken) {
        setState(() => _thumbs = const []);
      }
    } finally {
      if (mounted && myToken == _thumbsLoadToken) {
        setState(() => _thumbsLoading = false);
      }
    }
  }

  void _maybeRefetchThumbsForZoom() {
    final px = ed.timelinePxPerMs;
    if (px == _thumbLastPxPerMs) return;
    _thumbLastPxPerMs = px;
    final bucket = _thumbBucketForZoom(px, ed.totalDurationMs);
    if (bucket == _thumbActiveBucket && _thumbBuckets.containsKey(bucket)) {
      return;
    }
    // Swap to cached bucket immediately if present; otherwise debounce a
    // native fetch so rapid pinch frames don't queue duplicate platform calls.
    final cached = _thumbBuckets[bucket];
    if (cached != null) {
      _thumbActiveBucket = bucket;
      setState(() => _thumbs = cached);
      return;
    }
    _thumbRefetchTimer?.cancel();
    _thumbRefetchTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      unawaited(_loadThumbs(ed.videoPath, count: bucket));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autosaveTimer?.cancel();
    _savedFlashTimer?.cancel();
    _thumbRefetchTimer?.cancel();
    unawaited(ProjectIO.save(ed));
    _posTicker?.dispose();
    _ctrl?.removeListener(_onControllerChange);
    _ctrl?.dispose();
    ed.removeListener(_onStateChanged);
    super.dispose();
  }

  // ─── Undo / Redo ──────────────────────────────────────────────────

  void _pushUndo(String label) {
    _undo.add(EditorSnapshot.from(ed, label));
    if (_undo.length > 40) _undo.removeAt(0);
    _redo.clear();
  }

  void _onUndo() {
    if (_undo.isEmpty) return;
    final snap = _undo.removeLast();
    _redo.add(EditorSnapshot.from(ed, 'redo'));
    snap.applyTo(ed);
    ed.notify();
  }

  void _onRedo() {
    if (_redo.isEmpty) return;
    final snap = _redo.removeLast();
    _undo.add(EditorSnapshot.from(ed, 'undo'));
    snap.applyTo(ed);
    ed.notify();
  }

  // ─── Pro shuttle (J/K/L + 1-5 speed presets) ──────────────────────
  // Temporarily overrides ed.clipSpeed for preview only. _shuttleStop()
  // restores clip speed without touching state (no undo entry).

  double _nextShuttleUp(double r) {
    for (final v in _shuttleUpLadder) {
      if (v > r + 1e-6) return v;
    }
    return _shuttleUpLadder.last;
  }

  double _nextShuttleDown(double r) {
    for (final v in _shuttleDownLadder) {
      if (v < r - 1e-6) return v;
    }
    return _shuttleDownLadder.last;
  }

  Future<void> _shuttleSet(double rate) async {
    final c = _ctrl;
    if (c == null) return;
    HapticFeedback.selectionClick();
    _shuttleRate = rate;
    _shuttleActive = true;
    await c.setPlaybackSpeed(rate);
    if (!c.value.isPlaying) {
      await c.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _shuttleUp() async {
    await _shuttleSet(_nextShuttleUp(_shuttleActive ? _shuttleRate : 1.0));
  }

  Future<void> _shuttleDown() async {
    await _shuttleSet(_nextShuttleDown(_shuttleActive ? _shuttleRate : 1.0));
  }

  Future<void> _shuttleStop() async {
    final c = _ctrl;
    if (c == null) return;
    HapticFeedback.selectionClick();
    _shuttleActive = false;
    _shuttleRate = 1.0;
    await c.setPlaybackSpeed(ed.clipSpeed);
    await c.pause();
    if (mounted) setState(() {});
  }

  // ─── Loop region (I / O / [ ) ─────────────────────────────────────

  String _fmtShortMs(int ms) {
    final s = ms ~/ 1000;
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  void _setLoopIn() {
    HapticFeedback.selectionClick();
    final pos = ed.positionMs;
    setState(() {
      _loopInMs = pos;
      if (_loopOutMs != null && _loopOutMs! <= pos) _loopOutMs = null;
    });
    _toast('Loop IN ${_fmtShortMs(pos)}');
  }

  void _setLoopOut() {
    HapticFeedback.selectionClick();
    final pos = ed.positionMs;
    if (_loopInMs != null && pos <= _loopInMs!) {
      _toast('Loop OUT must be after IN');
      return;
    }
    setState(() => _loopOutMs = pos);
    _toast('Loop OUT ${_fmtShortMs(pos)}');
  }

  void _toggleLoop() {
    if (_loopInMs == null || _loopOutMs == null) {
      _toast('Set loop IN (I) and OUT (O) first');
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _loopEnabled = !_loopEnabled);
    _toast(_loopEnabled ? 'Loop ON' : 'Loop OFF');
  }

  void _clearLoop() {
    if (_loopInMs == null && _loopOutMs == null && !_loopEnabled) return;
    HapticFeedback.lightImpact();
    setState(() {
      _loopInMs = null;
      _loopOutMs = null;
      _loopEnabled = false;
    });
    _toast('Loop cleared');
  }

  // ─── Fullscreen ───────────────────────────────────────────────────

  Future<void> _openFullscreen() async {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final wasPlaying = c.value.isPlaying;
    final pos = c.value.position;
    if (wasPlaying) await c.pause();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullscreenPreview(controller: c),
      ),
    );
    // video_player binds the platform Surface to whichever VideoPlayer widget
    // mounted last; popping the fullscreen route leaves the edit-screen widget
    // with a detached surface → black frame. Re-seeking forces the plugin to
    // rebind the Surface to the surviving widget's Texture.
    if (!mounted) return;
    await c.seekTo(pos);
    if (wasPlaying) await c.play();
    if (mounted) setState(() {});
  }

  // ─── Playback ─────────────────────────────────────────────────────

  void _togglePlay() {
    final c = _ctrl;
    if (c == null) return;
    HapticFeedback.lightImpact();
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() {});
  }

  Future<void> _seekTo(int ms) async {
    final c = _ctrl;
    if (c == null) return;
    final clamped = ms.clamp(0, ed.totalDurationMs);
    await c.seekTo(Duration(milliseconds: clamped));
    ed.positionMs = clamped;
    ed.notify();
  }

  int _frameMs() => (1000 / ed.frameRateHint.clamp(1, 240)).round();

  Future<void> _stepFrames(int frames) async {
    final next = (ed.positionMs + frames * _frameMs())
        .clamp(0, ed.totalDurationMs);
    await _seekTo(next);
  }

  Future<void> _jumpToEdge(int direction) async {
    final pos = ed.positionMs;
    final edges = <int>{0, ed.totalDurationMs};
    for (final c in ed.clips) {
      edges
        ..add(c.inMs)
        ..add(c.outMs);
    }
    final sorted = edges.toList()..sort();
    if (direction > 0) {
      final next = sorted.firstWhere((e) => e > pos, orElse: () => pos);
      await _seekTo(next);
    } else {
      final prev = sorted.lastWhere((e) => e < pos, orElse: () => pos);
      await _seekTo(prev);
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent ev) {
    if (ev is! KeyDownEvent) return KeyEventResult.ignored;
    final k = ev.logicalKey;
    if (k == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      unawaited(_stepFrames(-1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      unawaited(_stepFrames(1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.comma) {
      unawaited(_jumpToEdge(-1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.period) {
      unawaited(_jumpToEdge(1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyS) {
      unawaited(_doSplit());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyZ) {
      _onUndo();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyY) {
      _onRedo();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyD) {
      unawaited(_duplicateSelected());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete ||
        k == LogicalKeyboardKey.backspace) {
      unawaited(_deleteSelected());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyC) {
      _copySelected();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyV) {
      _pasteAtPlayhead();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyL) {
      unawaited(_shuttleUp());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyJ) {
      unawaited(_shuttleDown());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyK) {
      unawaited(_shuttleStop());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit1) {
      unawaited(_shuttleSet(0.25));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit2) {
      unawaited(_shuttleSet(0.5));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit3) {
      unawaited(_shuttleSet(1.0));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit4) {
      unawaited(_shuttleSet(2.0));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.digit5) {
      unawaited(_shuttleSet(4.0));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyI) {
      _setLoopIn();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyO) {
      _setLoopOut();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.bracketLeft) {
      _toggleLoop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.bracketRight) {
      _clearLoop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.slash || k == LogicalKeyboardKey.question) {
      setState(() => _showShortcuts = !_showShortcuts);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_showShortcuts) {
        setState(() => _showShortcuts = false);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // ─── Toast / Busy ─────────────────────────────────────────────────

  void _toast(String msg) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        backgroundColor: kBgSurface,
      ),
    );
  }

  Future<T> _busyDo<T>(String label, Future<T> Function() task) async {
    setState(() {
      _busy = true;
      _busyLabel = label;
    });
    try {
      return await task();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  // ─── Edit actions ─────────────────────────────────────────────────

  Future<void> _doTrim() async {
    if (!minisReelClipTrimmerPlatformSupported()) {
      _toast('Trim works on Android / iOS only');
      return;
    }
    final result = await MinisReelClipTrimmerPage.open(
      context,
      File(ed.videoPath),
    );
    if (!mounted || result == null) return;
    _pushUndo('trim');
    await _swapVideo(result.path);
    _toast('Trimmed');
  }

  Future<void> _swapVideo(String path) async {
    final old = _ctrl;
    setState(() {
      _ctrl = null;
      ed.videoPath = path;
      _thumbs = const [];
      _thumbsLoading = false;
    });
    _thumbBuckets.clear();
    _thumbRefetchTimer?.cancel();
    _thumbLastPxPerMs = 0;
    ++_thumbsLoadToken;
    await old?.dispose();
    await _init();
  }

  Future<void> _doSplit() async {
    if (ed.clips.isEmpty) return;
    final pos = ed.positionMs;
    final idx = ed.clips.indexWhere((c) => pos >= c.inMs && pos < c.outMs);
    if (idx < 0) {
      _toast('Playhead not on a clip');
      return;
    }
    _pushUndo('split');
    final c = ed.clips[idx];
    final left = ClipSegment(
      id: '${c.id}_a',
      inMs: c.inMs,
      outMs: pos,
      speed: c.speed,
      muted: c.muted,
    );
    final right = ClipSegment(
      id: '${c.id}_b',
      inMs: pos,
      outMs: c.outMs,
      speed: c.speed,
      muted: c.muted,
    );
    ed.clips.removeAt(idx);
    ed.clips.insertAll(idx, [left, right]);
    ed.notify();
    _toast('Split at ${_fmtMs(pos)}');
  }

  Future<void> _doDeleteClip() async {
    if (ed.clips.length <= 1) {
      _toast('Cannot delete only clip');
      return;
    }
    final selId = ed.selectedClipId;
    int idx;
    if (selId != null) {
      idx = ed.clips.indexWhere((c) => c.id == selId);
      if (idx < 0) idx = -1;
    } else {
      idx = -1;
    }
    if (idx < 0) {
      final pos = ed.positionMs;
      idx = ed.clips.indexWhere((c) => pos >= c.inMs && pos < c.outMs);
    }
    if (idx < 0) return;
    final ok = await _confirm(
      title: 'Delete clip?',
      body: 'Subsequent clips slide left to close the gap. You can undo.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    _pushUndo('delete');
    final removed = ed.clips.removeAt(idx);
    final shift = removed.outMs - removed.inMs;
    // Ripple-shift later clips so timeline has no gap.
    for (var i = idx; i < ed.clips.length; i++) {
      ed.clips[i].inMs = (ed.clips[i].inMs - shift).clamp(0, ed.totalDurationMs);
      ed.clips[i].outMs = (ed.clips[i].outMs - shift).clamp(0, ed.totalDurationMs);
    }
    ed.selectedClipId = null;
    ed.notify();
    _toast('Clip removed (ripple)');
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 16)),
        content: Text(body,
            style: const TextStyle(color: kTextSecondary, fontSize: 13)),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: kTextSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor:
                  destructive ? const Color(0xFFE53935) : kAccentCyan,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text(confirmLabel,
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  Future<void> _doDuplicateClip() async {
    final pos = ed.positionMs;
    final idx = ed.clips.indexWhere((c) => pos >= c.inMs && pos < c.outMs);
    if (idx < 0) return;
    _pushUndo('duplicate');
    final c = ed.clips[idx];
    ed.clips.insert(idx + 1, ClipSegment(
      id: '${c.id}_dup${DateTime.now().millisecondsSinceEpoch}',
      inMs: c.inMs,
      outMs: c.outMs,
      speed: c.speed,
      muted: c.muted,
    ));
    ed.notify();
    _toast('Duplicated');
  }

  ClipSegment? _currentClip() {
    if (ed.clips.isEmpty) return null;
    final pos = ed.positionMs;
    final idx = ed.clips.indexWhere((c) => pos >= c.inMs && pos < c.outMs);
    return idx < 0 ? ed.clips.first : ed.clips[idx];
  }

  Future<void> _deleteSelected() async {
    final overlayId = ed.selectedOverlayId;
    final clipId = ed.selectedClipId;
    if (overlayId != null) {
      final ti = ed.texts.indexWhere((t) => t.id == overlayId);
      if (ti >= 0) {
        _pushUndo('text.delete');
        ed.texts.removeAt(ti);
        ed.selectedOverlayId = null;
        ed.notify();
        _toast('Text removed');
        return;
      }
      final si = ed.stickers.indexWhere((s) => s.id == overlayId);
      if (si >= 0) {
        _pushUndo('sticker.delete');
        ed.stickers.removeAt(si);
        ed.selectedOverlayId = null;
        ed.notify();
        _toast('Sticker removed');
        return;
      }
      final ai = ed.audios.indexWhere((a) => a.id == overlayId);
      if (ai >= 0) {
        _pushUndo('audio.delete');
        ed.audios.removeAt(ai);
        ed.selectedOverlayId = null;
        ed.notify();
        _toast('Audio removed');
        return;
      }
    }
    if (clipId != null) {
      await _doDeleteClip();
    }
  }

  Future<void> _duplicateSelected() async {
    final overlayId = ed.selectedOverlayId;
    if (overlayId != null) {
      final ti = ed.texts.indexWhere((t) => t.id == overlayId);
      if (ti >= 0) {
        _pushUndo('text.duplicate');
        final t = ed.texts[ti];
        ed.texts.add(TextOverlay(
          id: 'txt_${DateTime.now().microsecondsSinceEpoch}',
          text: t.text,
          color: t.color,
          bgColor: t.bgColor,
          fontSize: t.fontSize,
          bold: t.bold,
          italic: t.italic,
          align: t.align,
          fontFamily: t.fontFamily,
          position: t.position,
          startMs: t.endMs,
          endMs: math.min(ed.totalDurationMs, t.endMs + (t.endMs - t.startMs)),
          lane: t.lane,
        ));
        ed.notify();
        _toast('Duplicated');
        return;
      }
      final ai = ed.audios.indexWhere((a) => a.id == overlayId);
      if (ai >= 0) {
        _pushUndo('audio.duplicate');
        final a = ed.audios[ai];
        final dur = a.outMs == 0x7fffffff
            ? ed.totalDurationMs
            : (a.outMs - a.inMs);
        ed.audios.add(AudioTrack(
          id: 'aud_${DateTime.now().microsecondsSinceEpoch}',
          path: a.path,
          label: a.label,
          startMs: a.startMs + dur,
          inMs: a.inMs,
          outMs: a.outMs,
          volume: a.volume,
          muted: a.muted,
          fadeInMs: a.fadeInMs,
          fadeOutMs: a.fadeOutMs,
        ));
        ed.notify();
        _toast('Duplicated');
        return;
      }
    }
    if (ed.selectedClipId != null) {
      await _doDuplicateClip();
    }
  }

  Future<void> showBlockMenu({
    required String kind,
    required String id,
  }) async {
    final entries = <(String, IconData, VoidCallback)>[];
    entries.add(('Duplicate', Icons.copy, () {
      _setSelection(kind: kind, id: id);
      unawaited(_duplicateSelected());
    }));
    entries.add(('Delete', Icons.delete_outline, () {
      _setSelection(kind: kind, id: id);
      unawaited(_deleteSelected());
    }));
    if (kind == 'audio') {
      entries.add(('Toggle mute', Icons.volume_off, () {
        ed.toggleAudioMute(id);
      }));
    }
    if (kind == 'text') {
      entries.add(('Bring forward', Icons.arrow_upward, () {
        final t = ed.texts.firstWhere((e) => e.id == id);
        t.lane = (t.lane + 1).clamp(0, 31);
        ed.notify();
      }));
      entries.add(('Send backward', Icons.arrow_downward, () {
        final t = ed.texts.firstWhere((e) => e.id == id);
        t.lane = (t.lane - 1).clamp(0, 31);
        ed.notify();
      }));
      entries.add(('Set motion endpoint here', Icons.animation, () {
        final t = ed.texts.firstWhere((e) => e.id == id);
        _pushUndo('text.keyframe');
        t.endPosition = t.position;
        // Shift endpoint slightly so user can drag it to where they want.
        t.endPosition = Offset(
          (t.position.dx + 0.15).clamp(0.0, 1.0),
          t.position.dy,
        );
        ed.notify();
        _toast('Motion endpoint set — drag head/tail');
      }));
      entries.add(('Clear motion', Icons.clear, () {
        final t = ed.texts.firstWhere((e) => e.id == id);
        _pushUndo('text.clearKeyframe');
        t.endPosition = null;
        ed.notify();
      }));
    }
    if (kind == 'audio') {
      entries.add(('Toggle normalize', Icons.equalizer, () {
        final a = ed.audios.firstWhere((e) => e.id == id);
        a.normalize = !a.normalize;
        ed.notify();
        _toast(a.normalize ? 'Normalize ON' : 'Normalize OFF');
      }));
      entries.add(('Toggle ducking', Icons.volume_down, () {
        final a = ed.audios.firstWhere((e) => e.id == id);
        a.ducking = !a.ducking;
        ed.notify();
        _toast(a.ducking ? 'Ducking ON' : 'Ducking OFF');
      }));
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgSurface,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in entries)
                ListTile(
                  dense: true,
                  leading: Icon(e.$2, color: Colors.white),
                  title: Text(e.$1,
                      style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    e.$3();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _copySelected() {
    final id = ed.selectedOverlayId;
    if (id == null) return;
    final t = ed.texts.firstWhere(
      (e) => e.id == id,
      orElse: () => TextOverlay(id: '__none__', text: '', startMs: 0, endMs: 0),
    );
    if (t.id != '__none__') {
      _clipboard = t;
      _toast('Text copied');
      return;
    }
    final a = ed.audios.firstWhere(
      (e) => e.id == id,
      orElse: () =>
          AudioTrack(id: '__none__', path: '', label: '', startMs: 0),
    );
    if (a.id != '__none__') {
      _clipboard = a;
      _toast('Audio copied');
    }
  }

  void _pasteAtPlayhead() {
    final clip = _clipboard;
    if (clip == null) {
      _toast('Clipboard empty');
      return;
    }
    if (clip is TextOverlay) {
      _pushUndo('text.paste');
      final dur = clip.endMs - clip.startMs;
      ed.texts.add(TextOverlay(
        id: 'txt_${DateTime.now().microsecondsSinceEpoch}',
        text: clip.text,
        color: clip.color,
        bgColor: clip.bgColor,
        fontSize: clip.fontSize,
        bold: clip.bold,
        italic: clip.italic,
        align: clip.align,
        fontFamily: clip.fontFamily,
        position: clip.position,
        startMs: ed.positionMs,
        endMs: math.min(ed.totalDurationMs, ed.positionMs + dur),
        lane: ed.nextTextLane(),
      ));
      ed.notify();
      _toast('Pasted');
      return;
    }
    if (clip is AudioTrack) {
      _pushUndo('audio.paste');
      final dur = clip.outMs == 0x7fffffff
          ? ed.totalDurationMs
          : (clip.outMs - clip.inMs);
      ed.audios.add(AudioTrack(
        id: 'aud_${DateTime.now().microsecondsSinceEpoch}',
        path: clip.path,
        label: clip.label,
        startMs: ed.nextAudioStartMs(),
        inMs: clip.inMs,
        outMs: clip.inMs + dur,
        volume: clip.volume,
        muted: clip.muted,
        fadeInMs: clip.fadeInMs,
        fadeOutMs: clip.fadeOutMs,
      ));
      ed.notify();
      _toast('Pasted');
    }
  }

  Future<void> _resetAllEdits() async {
    final ok = await _confirm(
      title: 'Reset all edits?',
      body: 'All clips, text, audio, captions and adjustments will be cleared. '
          'You will be left with the original video as a single clip.',
      confirmLabel: 'Reset',
      destructive: true,
    );
    if (!ok) return;
    _pushUndo('reset');
    final dur = ed.totalDurationMs;
    ed.clips
      ..clear()
      ..add(ClipSegment(id: 'clip0', inMs: 0, outMs: dur));
    ed.texts.clear();
    ed.stickers.clear();
    ed.strokes.clear();
    ed.audios.clear();
    ed.captions.clear();
    ed.adjust.reset();
    ed.filter = FilterPreset.none;
    ed.bgMode = BackgroundMode.none;
    ed.aspect = AspectMode.original;
    ed.notify();
    _toast('Project reset');
  }

  void _setSelection({required String kind, required String id}) {
    if (kind == 'clip') {
      ed.selectedClipId = id;
      ed.selectedOverlayId = null;
    } else {
      ed.selectedOverlayId = id;
      ed.selectedClipId = null;
    }
  }

  Future<void> _doReplaceClip() async {
    final c = _currentClip();
    if (c == null) {
      _toast('No clip selected');
      return;
    }
    final file = await NativePicker.pickVideo();
    if (file == null) return;
    final ok = await _confirm(
      title: 'Replace clip?',
      body: 'Current clip will be replaced with the selected video. You can undo.',
      confirmLabel: 'Replace',
    );
    if (!ok) return;
    _pushUndo('replace');
    await _swapVideo(file.path);
    _toast('Replaced');
  }

  Future<void> _doReverseClip() async {
    final c = _currentClip();
    if (c == null) {
      _toast('No clip selected');
      return;
    }
    _pushUndo('reverse');
    c.reversed = !c.reversed;
    ed.notify();
    _toast(c.reversed ? 'Reversed (applies on export)' : 'Reverse off');
  }

  Future<void> _doStabilize() async {
    final c = _currentClip();
    if (c == null) {
      _toast('No clip selected');
      return;
    }
    final mode = await showStabilizeSheet(context,
        current: c.stabilizeMode ?? 'medium');
    if (mode == null) return;
    _pushUndo('stabilize');
    c.stabilizeMode = mode == 'off' ? null : mode;
    ed.notify();
    if (mode == 'off') {
      _toast('Stabilize off');
      return;
    }
    if (!await MinisVidEdit.instance.isAvailable()) {
      _toast('Stabilize requires Android or iOS native build');
      return;
    }
    try {
      await _busyDo('Stabilizing…', () async {
        await MinisVidEdit.instance.stabilize(clipId: c.id, mode: mode);
      });
      _toast('Stabilized ($mode)');
    } catch (e) {
      _toast('Stabilize failed: $e');
    }
  }

  Future<void> _doMask() async {
    final c = _currentClip();
    if (c == null) {
      _toast('No clip selected');
      return;
    }
    final ok = await showMaskSheet(context, c);
    if (ok != true) return;
    _pushUndo('mask');
    ed.notify();
    _toast(c.maskShape == 'none' ? 'Mask removed' : 'Mask: ${c.maskShape}');
  }

  Future<void> _doChroma() async {
    final c = _currentClip();
    if (c == null) {
      _toast('No clip selected');
      return;
    }
    final ok = await showChromaSheet(context, c);
    if (ok != true) return;
    _pushUndo('chroma');
    ed.notify();
    _toast(c.chromaKeyColor == null
        ? 'Chroma key off'
        : 'Chroma key applied');
  }

  Future<void> _doAudioFade() async {
    if (ed.audios.isEmpty) {
      _toast('Add an audio track first');
      return;
    }
    AudioTrack? track;
    if (ed.audios.length == 1) {
      track = ed.audios.first;
    } else {
      final label = await showSimplePickerSheet(
        context,
        title: 'Pick audio track',
        options: [for (final a in ed.audios) a.label],
      );
      if (label == null) return;
      track = ed.audios.firstWhere((a) => a.label == label,
          orElse: () => ed.audios.first);
    }
    if (!mounted) return;
    final ok = await showAudioFadeSheet(context, track);
    if (ok != true) return;
    _pushUndo('audio.fade');
    ed.notify();
    _toast('Fade ${track.fadeInMs}/${track.fadeOutMs}ms');
  }

  Future<void> _doTextAnim() async {
    if (ed.texts.isEmpty) {
      _toast('Add text first');
      return;
    }
    TextOverlay? sel;
    if (ed.selectedOverlayId != null) {
      sel = ed.texts.firstWhere(
        (t) => t.id == ed.selectedOverlayId,
        orElse: () => ed.texts.last,
      );
    }
    sel ??= ed.texts.last;
    final ok = await showTextAnimationSheet(context, sel);
    if (ok != true) return;
    _pushUndo('text.anim');
    ed.notify();
    _toast(sel.animationName == null
        ? 'Animation removed'
        : '${sel.animationName} ${sel.animationDirection.label}');
  }

  Future<void> _doSpeed() async {
    final picked = await showSpeedSheet(context, ed.clipSpeed);
    if (picked == null) return;
    _pushUndo('speed');
    ed.clipSpeed = picked;
    await _ctrl?.setPlaybackSpeed(picked);
    ed.notify();
  }

  Future<void> _doVolume() async {
    final v = await showVolumeSheet(context, ed.clipVolume);
    if (v == null) return;
    _pushUndo('volume');
    ed.clipVolume = v;
    await _ctrl?.setVolume(v);
    ed.notify();
  }

  Future<void> _doMute() async {
    _pushUndo('mute');
    ed.clipMuted = !ed.clipMuted;
    await _ctrl?.setVolume(ed.clipMuted ? 0 : 1);
    ed.notify();
    _toast(ed.clipMuted ? 'Clip muted' : 'Clip unmuted');
  }

  Future<void> _doCover() async {
    _pushUndo('cover');
    ed.coverMs = ed.positionMs;
    ed.notify();
    _toast('Cover set at ${_fmtMs(ed.coverMs)}');
  }

  // ─── Audio sub-menu ───────────────────────────────────────────────

  Future<void> _audioPickFile() async {
    final item = await NativePicker.pickFile(
      mimeTypes: const ['audio/*'],
      extensions: const ['mp3', 'm4a', 'aac', 'wav', 'ogg'],
    );
    if (item.isEmpty) return;
    _pushUndo('audio.add');
    final f = item.first;
    final startMs = ed.nextAudioStartMs();
    ed.audios.add(AudioTrack(
      id: 'aud_${DateTime.now().microsecondsSinceEpoch}',
      path: f.path,
      label: f.name ?? 'Audio',
      startMs: startMs,
      inMs: 0,
      outMs: f.durationMs > 0 ? f.durationMs : ed.totalDurationMs,
    ));
    ed.notify();
    _toast('Audio added');
  }

  Future<void> _audioExtractFromVideo() async {
    final v = await NativePicker.pickVideo();
    if (v == null) return;
    _pushUndo('audio.extract');
    final startMs = ed.nextAudioStartMs();
    ed.audios.add(AudioTrack(
      id: 'aud_${DateTime.now().microsecondsSinceEpoch}',
      path: v.path,
      label: 'Extracted: ${v.name ?? "audio"}',
      startMs: startMs,
      inMs: 0,
      outMs: v.durationMs > 0 ? v.durationMs : ed.totalDurationMs,
    ));
    ed.notify();
    _toast('Audio extracted');
  }

  Future<void> _audioVoiceover() async {
    final path = await showVoiceoverSheet(context);
    if (path == null) return;
    _pushUndo('audio.voiceover');
    final startMs = ed.nextAudioStartMs();
    ed.audios.add(AudioTrack(
      id: 'vo_${DateTime.now().microsecondsSinceEpoch}',
      path: path,
      label: 'Voiceover',
      startMs: startMs,
      inMs: 0,
      outMs: ed.totalDurationMs,
      ducking: true,
    ));
    ed.notify();
    _toast('Voiceover recorded');
  }

  Future<void> _audioTts() async {
    final text = await showTextEntrySheet(context, title: 'Text to audio');
    if (text == null || text.isEmpty) return;
    _pushUndo('audio.tts');
    final startMs = ed.nextAudioStartMs();
    final durMs = math.max(2000, text.length * 80);
    ed.audios.add(AudioTrack(
      id: 'tts_${DateTime.now().microsecondsSinceEpoch}',
      path: '',
      label: 'TTS: $text',
      startMs: startMs,
      inMs: 0,
      outMs: startMs + durMs,
    ));
    ed.notify();
    _toast('TTS clip added (dummy)');
  }

  Future<void> _audioCopyrightCheck() async {
    if (ed.audios.isEmpty) {
      _toast('No audio tracks to check');
      return;
    }
    await _busyDo('Checking copyright…',
        () => Future<void>.delayed(const Duration(seconds: 1)));
    _toast('All audio cleared ✓');
  }

  // ─── Text sub-menu ────────────────────────────────────────────────

  Future<void> _textAdd({String? template}) async {
    final text = await showTextEditorSheet(context, initial: template ?? '');
    if (text == null) return;
    _pushUndo('text.add');
    ed.texts.add(TextOverlay(
      id: 'txt_${DateTime.now().microsecondsSinceEpoch}',
      text: text.text,
      color: text.color,
      bgColor: text.bgColor,
      fontSize: text.fontSize,
      bold: text.bold,
      italic: text.italic,
      align: text.align,
      position: const Offset(0.5, 0.4),
      startMs: ed.positionMs,
      endMs: math.min(ed.totalDurationMs, ed.positionMs + 4000),
      lane: ed.nextTextLane(),
    ));
    ed.notify();
  }

  Future<void> _editTextOverlay(TextOverlay t) async {
    final res = await showTextEditorSheet(context, initial: t.text);
    if (res == null) return;
    _pushUndo('text.edit');
    t.text = res.text;
    t.color = res.color;
    t.bgColor = res.bgColor;
    t.fontSize = res.fontSize;
    t.bold = res.bold;
    t.italic = res.italic;
    t.align = res.align;
    ed.notify();
  }

  Future<void> _textDraw() async {
    final stroke = await showDrawSheet(context);
    if (stroke == null) return;
    _pushUndo('draw.add');
    ed.strokes.add(stroke);
    ed.notify();
  }

  Future<void> _textAutoLyrics() async {
    _pushUndo('lyrics.add');
    const samples = [
      ('We could be heroes', 0, 3000),
      ('Just for one day', 3000, 6000),
    ];
    final baseLane = ed.nextTextLane();
    for (final s in samples) {
      ed.texts.add(TextOverlay(
        id: 'lyr_${DateTime.now().microsecondsSinceEpoch}_${s.$2}',
        text: s.$1,
        color: Colors.white,
        bgColor: Colors.black.withValues(alpha: 0.4),
        fontSize: 28,
        bold: true,
        position: const Offset(0.5, 0.8),
        startMs: ed.positionMs + s.$2,
        endMs: math.min(ed.totalDurationMs, ed.positionMs + s.$3),
        lane: baseLane,
      ));
    }
    ed.notify();
    _toast('Sample lyrics added (dummy)');
  }

  // ─── Effects sub-menu ─────────────────────────────────────────────

  Future<void> _effectsVideo() async {
    final preset = await showSimplePickerSheet(
      context,
      title: 'Video effects',
      options: const ['None', 'Glitch', 'VHS', 'Shake', 'Pulse', 'Zoom'],
    );
    if (preset == null) return;
    _pushUndo('fx.video');
    if (preset == 'None') {
      ed.filter = FilterPreset.none;
    } else if (preset == 'VHS') {
      ed.filter = FilterPreset.vintage;
    } else if (preset == 'Glitch') {
      ed.filter = FilterPreset.drama;
    }
    ed.notify();
    _toast('Effect: $preset');
  }

  Future<void> _effectsBody() async {
    final preset = await showSimplePickerSheet(
      context,
      title: 'Body effects (dummy)',
      options: const ['None', 'Smooth skin', 'Slim face', 'Big eyes', 'Anime'],
    );
    if (preset == null) return;
    _toast('Applied: $preset (dummy)');
  }

  Future<void> _effectsPhoto() async {
    final preset = await showSimplePickerSheet(
      context,
      title: 'Photo effects',
      options: const ['None', 'Blur edge', 'Vignette', 'Light leak', '3D pop'],
    );
    if (preset == null) return;
    _toast('Effect: $preset');
  }

  // ─── Overlay ──────────────────────────────────────────────────────

  Future<void> _addOverlay() async {
    final choice = await showOverlayPickerSheet(context);
    if (choice == null) return;
    switch (choice) {
      case 'text':
        await _textAdd();
        break;
      case 'sticker':
        await _openStickersPanel();
        break;
      case 'picture':
        final p = await NativePicker.pickImage();
        if (p != null) {
          _pushUndo('overlay.image');
          ed.stickers.add(StickerOverlay(
            id: 'pic_${DateTime.now().microsecondsSinceEpoch}',
            url: 'file://${p.path}',
            aspect: p.width > 0 && p.height > 0 ? p.width / p.height : 1.0,
            isGif: false,
            startMs: ed.positionMs,
            endMs: ed.totalDurationMs,
          ));
          ed.notify();
        }
        break;
    }
  }

  // ─── Captions ─────────────────────────────────────────────────────

  Future<void> _captionEnter() async {
    final text = await showTextEntrySheet(context, title: 'Enter caption');
    if (text == null || text.isEmpty) return;
    _pushUndo('caption.add');
    ed.captions.add(Caption(
      id: 'cap_${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      startMs: ed.positionMs,
      endMs: math.min(ed.totalDurationMs, ed.positionMs + 3000),
    ));
    ed.notify();
  }

  Future<void> _captionAuto() async {
    final settings = await showAutoCaptionsSheet(context);
    if (settings == null) return;
    await _busyDo('Generating captions…',
        () => Future<void>.delayed(const Duration(milliseconds: 1500)));
    _pushUndo('caption.auto');
    final samples = [
      'Welcome back',
      'Check this out',
      'Amazing right?',
      'Like and subscribe',
    ];
    final step = math.max(2000, ed.totalDurationMs ~/ samples.length);
    for (var i = 0; i < samples.length; i++) {
      final start = i * step;
      if (start >= ed.totalDurationMs) break;
      ed.captions.add(Caption(
        id: 'auto_${DateTime.now().microsecondsSinceEpoch}_$i',
        text: samples[i],
        startMs: start,
        endMs: math.min(ed.totalDurationMs, start + step - 200),
      ));
    }
    ed.notify();
    _toast('Auto captions generated (dummy)');
  }

  Future<void> _captionTemplate() async {
    final tpl = await showSimplePickerSheet(
      context,
      title: 'Caption templates',
      options: const ['Bold white', 'Yellow box', 'Neon glow', 'Minimal', 'Karaoke'],
    );
    if (tpl == null) return;
    _toast('Template: $tpl applied');
  }

  Future<void> _captionImport() async {
    final files = await NativePicker.pickFile(
      mimeTypes: const ['text/*', 'application/x-subrip'],
      extensions: const ['srt', 'vtt', 'txt'],
    );
    if (files.isEmpty) return;
    final f = files.first;
    try {
      final raw = await File(f.path).readAsString();
      final caps = _parseSrt(raw);
      _pushUndo('caption.import');
      ed.captions.addAll(caps);
      ed.notify();
      _toast('Imported ${caps.length} caption(s)');
    } catch (e) {
      _toast('Failed: $e');
    }
  }

  List<Caption> _parseSrt(String raw) {
    final out = <Caption>[];
    final blocks = raw.split(RegExp(r'\r?\n\r?\n'));
    final tsRe = RegExp(r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})');
    for (final b in blocks) {
      final lines = b.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
      if (lines.length < 2) continue;
      final m = tsRe.firstMatch(lines[1]) ?? tsRe.firstMatch(lines[0]);
      if (m == null) continue;
      final startMs = int.parse(m.group(1)!) * 3600000 +
          int.parse(m.group(2)!) * 60000 +
          int.parse(m.group(3)!) * 1000 +
          int.parse(m.group(4)!);
      final endMs = int.parse(m.group(5)!) * 3600000 +
          int.parse(m.group(6)!) * 60000 +
          int.parse(m.group(7)!) * 1000 +
          int.parse(m.group(8)!);
      final textLines = lines.where((l) => !tsRe.hasMatch(l) && !RegExp(r'^\d+$').hasMatch(l.trim())).join('\n');
      out.add(Caption(
        id: 'srt_${DateTime.now().microsecondsSinceEpoch}_${out.length}',
        text: textLines,
        startMs: startMs,
        endMs: endMs,
      ));
    }
    return out;
  }

  // ─── Filters / Adjust ────────────────────────────────────────────

  Future<void> _openFiltersPanel() async {
    await showFiltersAdjustSheet(context, ed,
        onChanged: () => ed.notify(),
        onPushUndo: () => _pushUndo('adjust'));
  }

  // ─── Ratio / Background ──────────────────────────────────────────

  Future<void> _openRatio() async {
    ed.transformMode = true;
    ed.notify();
    try {
      final m = await showRatioSheet(context, ed.aspect);
      if (m == null) return;
      _pushUndo('ratio');
      ed.aspect = m;
      ed.notify();
    } finally {
      ed.transformMode = false;
      ed.notify();
    }
  }

  Future<void> _openBackground() async {
    ed.transformMode = true;
    ed.notify();
    try {
      await showBackgroundSheet(context, ed,
          onChanged: () => ed.notify(),
          onPushUndo: () => _pushUndo('bg'));
    } finally {
      ed.transformMode = false;
      ed.notify();
    }
  }

  // ─── Stickers / GIPHY ────────────────────────────────────────────

  Future<void> _openStickersPanel() async {
    final item = await showStickerSheet(context);
    if (item == null) return;
    _pushUndo('sticker.add');
    ed.stickers.add(StickerOverlay(
      id: 'gif_${DateTime.now().microsecondsSinceEpoch}',
      url: item.fullUrl,
      aspect: item.aspectRatio,
      isGif: true,
      startMs: ed.positionMs,
      endMs: ed.totalDurationMs,
    ));
    ed.notify();
  }

  Future<void> _replaceSticker(StickerOverlay current) async {
    final item = await showStickerSheet(context);
    if (item == null) return;
    final idx = ed.stickers.indexOf(current);
    if (idx < 0) return;
    _pushUndo('sticker.replace');
    final replacement = StickerOverlay(
      id: current.id,
      url: item.fullUrl,
      aspect: item.aspectRatio,
      isGif: true,
      position: current.position,
      scale: current.scale,
      rotation: current.rotation,
      flipH: current.flipH,
      startMs: current.startMs,
      endMs: current.endMs,
    );
    ed.stickers[idx] = replacement;
    ed.notify();
  }

  // ─── Export ──────────────────────────────────────────────────────

  Future<void> _openExportSettings() async {
    await showExportSettingsSheet(context, ed,
        onChanged: () => ed.notify());
  }

  Future<void> _doExport() async {
    if (_ctrl == null || !(_ctrl?.value.isInitialized ?? false)) {
      _toast('Wait for video to load before exporting');
      return;
    }
    if (ed.clips.isEmpty) {
      _toast('Add at least one clip to export');
      return;
    }
    await showExportSettingsSheet(context, ed,
        onChanged: () => ed.notify());
    if (!mounted) return;

    if (!await MinisVidEdit.instance.isAvailable()) {
      _toast('Export requires Android or iOS native build');
      return;
    }

    StreamSubscription<VidEditProgress>? sub;
    setState(() {
      _busy = true;
      _busyLabel = 'Preparing…';
      _exportPct = 0;
      _exportTaskId = null;
    });
    try {
      final dir = await NativePaths.cacheDir() ?? Directory.systemTemp.path;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outPath = '$dir/export_$ts.mp4';

      final timeline = _buildExportTimeline();
      await MinisVidEdit.instance.loadTimeline(timeline);

      final preset = _presetForResolution(ed.export.resolution);
      final dims = _dimsForExport();
      final taskId = await MinisVidEdit.instance.export(
        preset: preset,
        outPath: outPath,
        options: VidEditExportOptions(
          maxResolution: dims,
          audioBitrate: 128000,
          hardwareAcceleration: true,
          targetBytes: _targetBytesFromBitrate(),
        ),
      );
      if (mounted) setState(() => _exportTaskId = taskId);

      final done = Completer<void>();
      sub = MinisVidEdit.instance.progressFor(taskId).listen((p) {
        if (!mounted) return;
        setState(() {
          _exportPct = p.pct.clamp(0.0, 1.0);
          _busyLabel = 'Exporting…';
        });
        if (p.pct >= 1.0 && !done.isCompleted) done.complete();
      }, onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      });

      await done.future.timeout(const Duration(minutes: 30));

      String finalPath = outPath;
      if (ed.captions.isNotEmpty) {
        if (mounted) {
          setState(() {
            _busyLabel = 'Burning captions…';
            _exportPct = null;
          });
        }
        final srt = await _writeSrtFile(ed.captions, dir);
        finalPath = '$dir/export_${ts}_captioned.mp4';
        await MinisVidEdit.instance.burnCaptions(
          inputPath: outPath,
          outputPath: finalPath,
          srtPath: srt,
        );
      }

      if (!mounted) return;
      _toast('Saved: $finalPath');
    } catch (e) {
      if (!mounted) return;
      _toast('Export failed: $e');
    } finally {
      await sub?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
          _exportPct = null;
          _exportTaskId = null;
        });
      }
    }
  }

  void _cancelExport() {
    final id = _exportTaskId;
    if (id == null) return;
    // Engine may or may not support cancel; best-effort.
    unawaited(MinisVidEdit.instance.cancelTask(id).catchError((_) {}));
    setState(() {
      _busy = false;
      _busyLabel = null;
      _exportPct = null;
      _exportTaskId = null;
    });
    _toast('Export cancelled');
  }

  VidEditTimeline _buildExportTimeline() {
    final clips = <VidEditClip>[];
    var position = 0;
    for (final c in ed.clips) {
      clips.add(VidEditClip(
        id: c.id,
        path: ed.videoPath,
        trackIndex: 0,
        inMs: c.inMs,
        outMs: c.outMs,
        positionMs: position,
        speed: c.speed,
        keepPitch: ed.keepMusicTempo,
        volume: (c.muted || ed.clipMuted) ? 0.0 : 1.0,
      ));
      position += c.durationMs;
    }
    for (final a in ed.audios) {
      clips.add(VidEditClip(
        id: a.id,
        path: a.path,
        trackIndex: 1,
        inMs: a.inMs,
        outMs: a.outMs == 0x7fffffff
            ? (a.outMs.clamp(0, ed.totalDurationMs))
            : a.outMs,
        positionMs: a.startMs,
        volume: a.effectiveVolume,
      ));
    }
    return VidEditTimeline(
      clips: clips,
      aspect: _aspectFor(ed.aspect),
    );
  }

  VidEditAspect _aspectFor(AspectMode m) {
    switch (m) {
      case AspectMode.r9x16:
        return VidEditAspect.portrait916;
      case AspectMode.r16x9:
        return VidEditAspect.landscape169;
      case AspectMode.r1x1:
        return VidEditAspect.square;
      case AspectMode.r4x3:
        return VidEditAspect.landscape169;
      case AspectMode.r3x4:
      case AspectMode.r5x8:
        return VidEditAspect.portrait45;
      case AspectMode.original:
        return VidEditAspect.source;
    }
  }

  ({int w, int h}) _dimsForExport() {
    final h = ed.export.resolution;
    final ratio = ed.aspect.ratio;
    int w;
    if (ratio == 0) {
      final size = _ctrl?.value.size ?? const Size(9, 16);
      final native = size.width / (size.height == 0 ? 1 : size.height);
      w = (h * native).round();
    } else {
      w = (h * ratio).round();
    }
    if (w.isOdd) w -= 1;
    final hh = h.isOdd ? h - 1 : h;
    return (w: w, h: hh);
  }

  int? _targetBytesFromBitrate() {
    if (ed.totalDurationMs <= 0) return null;
    return (ed.export.bitrate * 1000000 * ed.totalDurationMs ~/ 8000);
  }

  Future<String> _writeSrtFile(List<Caption> caps, String dir) async {
    final path = '$dir/captions_${DateTime.now().millisecondsSinceEpoch}.srt';
    final buf = StringBuffer();
    for (var i = 0; i < caps.length; i++) {
      final c = caps[i];
      buf
        ..writeln(i + 1)
        ..writeln('${_srtTime(c.startMs)} --> ${_srtTime(c.endMs)}')
        ..writeln(c.text)
        ..writeln();
    }
    await File(path).writeAsString(buf.toString());
    return path;
  }

  String _srtTime(int ms) {
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final mm = ms % 1000;
    final hh = h.toString().padLeft(2, '0');
    final mins = m.toString().padLeft(2, '0');
    final secs = s.toString().padLeft(2, '0');
    final mil = mm.toString().padLeft(3, '0');
    return '$hh:$mins:$secs,$mil';
  }

  VidEditExportPreset _presetForResolution(int h) {
    if (h >= 2160) return VidEditExportPreset.uhd4k;
    if (h >= 1080) return VidEditExportPreset.reel1080;
    return VidEditExportPreset.hd720;
  }

  // ─── Format helpers ──────────────────────────────────────────────

  String _fmtMs(int ms) {
    final s = (ms ~/ 1000).clamp(0, 359999);
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  // ─── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          _buildScaffold(),
          if (_showOnboarding)
            _OnboardingOverlay(onDismiss: () async {
              await OnboardingPrefs.markSeen();
              if (mounted) setState(() => _showOnboarding = false);
            }),
          if (_showShortcuts)
            _ShortcutsOverlay(
              onDismiss: () => setState(() => _showShortcuts = false),
            ),
          if (_shuttleActive)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: _ShuttlePill(rate: _shuttleRate),
                ),
              ),
            ),
          if (_loopInMs != null || _loopOutMs != null)
            Positioned(
              top: _shuttleActive ? 96 : 60,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: _LoopPill(
                    inMs: _loopInMs,
                    outMs: _loopOutMs,
                    enabled: _loopEnabled,
                    fmt: _fmtShortMs,
                  ),
                ),
              ),
            ),
          if (ed.showFps)
            Positioned(
              top: 60,
              right: 8,
              height: 80,
              width: 200,
              child: IgnorePointer(child: PerformanceOverlay.allEnabled()),
            ),
        ],
      ),
    );
  }

  Future<void> _showUndoHistory() async {
    if (_undo.isEmpty) {
      _toast('Nothing to undo');
      return;
    }
    final history = _undo.reversed.toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgSurface,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('History',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                ),
                Flexible(
                  child: ListView.builder(
                    itemCount: history.length,
                    itemBuilder: (_, i) {
                      final snap = history[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.history,
                            color: Colors.white54, size: 18),
                        title: Text(snap.label,
                            style: const TextStyle(color: Colors.white)),
                        trailing: Text('-${i + 1}',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          for (var k = 0; k <= i; k++) {
                            _onUndo();
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      backgroundColor: kBgBlack,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              resolution: ed.export.resolution,
              onClose: () => Get.back<void>(),
              onSearch: () => _toast('Search'),
              onResolution: _openExportSettings,
              onExport: _doExport,
              aspect: ed.aspect,
              onAspect: (a) {
                _pushUndo('aspect');
                ed.aspect = a;
                ed.notify();
              },
              savedFlash: _savedFlash,
              onReset: () => unawaited(_resetAllEdits()),
            ),
            // ─── Preview half ──────────────────────────────────────
            Expanded(
              flex: 1,
              child: Stack(
                children: [
                  RepaintBoundary(
                    child: _PreviewArea(
                      state: ed,
                      controller: _ctrl,
                      onEditOverlayText: _editTextOverlay,
                      onReplaceSticker: _replaceSticker,
                      onToast: _toast,
                      onTogglePlay: _togglePlay,
                      onSkipSeconds: (s) => unawaited(
                          _seekTo(ed.positionMs + s * 1000)),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _SafeZoneOverlay(
                        showSafe: ed.showSafeZones,
                        showGrid: ed.showGrid,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _PreviewControls(
                      isPlaying: ed.isPlaying,
                      canUndo: _undo.isNotEmpty,
                      canRedo: _redo.isNotEmpty,
                      snapOn: ed.snapEnabled,
                      safeOn: ed.showSafeZones,
                      gridOn: ed.showGrid,
                      positionMs: ed.positionMs,
                      durationMs: ed.totalDurationMs,
                      onPlay: _togglePlay,
                      onPrevFrame: () => unawaited(_stepFrames(-1)),
                      onNextFrame: () => unawaited(_stepFrames(1)),
                      onSplit: () => unawaited(_doSplit()),
                      onFullscreen: _openFullscreen,
                      onSnap: () {
                        HapticFeedback.selectionClick();
                        ed.snapEnabled = !ed.snapEnabled;
                        ed.notify();
                        _toast(ed.snapEnabled ? 'Snap ON' : 'Snap OFF');
                      },
                      onToggleSafe: () {
                        ed.showSafeZones = !ed.showSafeZones;
                        ed.notify();
                      },
                      onToggleGrid: () {
                        ed.showGrid = !ed.showGrid;
                        ed.notify();
                      },
                      onUndo: _onUndo,
                      onRedo: _onRedo,
                      onShowHistory: () => unawaited(_showUndoHistory()),
                    ),
                  ),
                  if (_busy)
                    _ExportBusy(
                      label: _busyLabel,
                      pct: _exportPct,
                      onCancel: _exportTaskId != null ? _cancelExport : null,
                    ),
                ],
              ),
            ),
            // ─── Timeline half ─────────────────────────────────────
            Expanded(
              flex: 1,
              child: RepaintBoundary(
                child: MultiTrackTimeline(
                  state: ed,
                  thumbs: _thumbs,
                  thumbsLoading: _thumbsLoading,
                  onSeek: _seekTo,
                  onAddText: () => _textAdd(),
                  onAddAudio: _audioPickFile,
                  onAddSticker: () => unawaited(_openStickersPanel()),
                  onAddCaption: () => unawaited(_captionAuto()),
                  onSplit: _doSplit,
                  onSelectClip: (id) {
                    ed.selectedClipId = id;
                    ed.selectedOverlayId = null;
                  },
                  onSelectText: (id) {
                    ed.selectedOverlayId = id;
                    ed.selectedClipId = null;
                  },
                  onSelectAudio: (id) {
                    ed.selectedOverlayId = id;
                    ed.selectedClipId = null;
                  },
                  onLongPressBlock: (kind, id) =>
                      unawaited(showBlockMenu(kind: kind, id: id)),
                ),
              ),
            ),
            _SubMenuArea(
              tool: _activeTool,
              onBack: () => setState(() => _activeTool = null),
              onAction: _handleSubMenuAction,
            ),
            if (!ed.suggestionDismissed &&
                _activeTool == null &&
                ed.audios.isNotEmpty)
              _SuggestionPill(
                icon: Icons.graphic_eq,
                label: 'Try noise reduction for clearer audio',
                estimate: '12s',
                onTap: () async {
                  await _busyDo('Reducing noise…',
                      () => Future<void>.delayed(
                          const Duration(milliseconds: 1200)));
                  ed.suggestionDismissed = true;
                  ed.notify();
                  _toast('Noise reduced ✓');
                },
                onDismiss: () {
                  ed.suggestionDismissed = true;
                  ed.notify();
                },
              ),
            if (ed.commitCancelMode)
              _CommitCancelBar(
                onCancel: () {
                  ed.commitCancelMode = false;
                  ed.notify();
                },
                onCommit: () {
                  HapticFeedback.mediumImpact();
                  ed.commitCancelMode = false;
                  ed.notify();
                },
              )
            else
              _BottomNav(
                active: _activeTool,
                onTap: (t) => setState(() => _activeTool = t),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleSubMenuAction(String action) async {
    switch (action) {
      // Edit
      case 'split':
        await _doSplit();
        break;
      case 'speed':
        await _doSpeed();
        break;
      case 'volume':
        await _doVolume();
        break;
      case 'mute':
        await _doMute();
        break;
      case 'cover':
        await _doCover();
        break;
      case 'delete':
        await _doDeleteClip();
        break;
      case 'duplicate':
        await _doDuplicateClip();
        break;
      case 'replace':
        await _doReplaceClip();
        break;
      case 'reverse':
        await _doReverseClip();
        break;
      case 'stabilize':
        await _doStabilize();
        break;
      case 'mask':
        await _doMask();
        break;
      case 'chroma':
        await _doChroma();
        break;
      case 'trim':
        await _doTrim();
        break;
      case 'ratio':
        await _openRatio();
        break;
      case 'background':
        await _openBackground();
        break;
      // Audio
      case 'audio.extract':
        await _audioExtractFromVideo();
        break;
      case 'audio.sounds':
        await _audioPickFile();
        break;
      case 'audio.sfx':
        await _audioPickFile();
        break;
      case 'audio.record':
        await _audioVoiceover();
        break;
      case 'audio.fade':
        await _doAudioFade();
        break;
      case 'audio.tts':
        await _audioTts();
        break;
      case 'audio.copyright':
        await _audioCopyrightCheck();
        break;
      // Text
      case 'text.add':
        await _textAdd();
        break;
      case 'text.stickers':
        await _openStickersPanel();
        break;
      case 'text.draw':
        await _textDraw();
        break;
      case 'text.anim':
        await _doTextAnim();
        break;
      case 'text.template':
        await _textAdd(template: 'TITLE');
        break;
      case 'text.tts':
        await _audioTts();
        break;
      case 'text.lyrics':
        await _textAutoLyrics();
        break;
      // Effects
      case 'fx.video':
        await _effectsVideo();
        break;
      case 'fx.body':
        await _effectsBody();
        break;
      case 'fx.photo':
        await _effectsPhoto();
        break;
      // Overlay
      case 'overlay.add':
        await _addOverlay();
        break;
      // Captions
      case 'cap.enter':
        await _captionEnter();
        break;
      case 'cap.auto':
        await _captionAuto();
        break;
      case 'cap.template':
        await _captionTemplate();
        break;
      case 'cap.lyrics':
        await _textAutoLyrics();
        break;
      case 'cap.import':
        await _captionImport();
        break;
      // Filters
      case 'filters.open':
        await _openFiltersPanel();
        break;
      // Audio (new)
      case 'audio.ducking':
        await _showDuckingSheet();
        break;
      case 'audio.eq':
        await _showEqSheet();
        break;
      case 'audio.beat':
        await _showBeatSheet();
        break;
      case 'audio.denoise':
        await _busyDo('Reducing noise…',
            () => Future<void>.delayed(const Duration(milliseconds: 900)));
        _toast('Noise reduced ✓');
        break;
      // Text (new)
      case 'text.kinetic':
        await _doTextAnim();
        break;
      case 'text.gradient':
        await _showGradientSheet();
        break;
      // Captions (new)
      case 'cap.wordsync':
        await _showWordSyncSheet();
        break;
      case 'cap.multilang':
        await _showTranslateSheet();
        break;
      // Stickers
      case 'sticker.emoji':
      case 'sticker.giphy':
      case 'sticker.recent':
        await _openStickersPanel();
        break;
      case 'sticker.search':
        await _openStickersPanel();
        break;
      case 'sticker.packs':
        await _showPacksSheet();
        break;
      case 'sticker.ar':
        await _showArSheet();
        break;
      // Video
      case 'video.transitions':
        await _showTransitionsSheet();
        break;
    }
  }

  // ─── Enterprise sub-sheets ────────────────────────────────────────

  Future<void> _showEqSheet() async {
    const presets = <(String, IconData)>[
      ('Flat', Icons.equalizer),
      ('Vocal', Icons.record_voice_over),
      ('Bass boost', Icons.speaker),
      ('Treble', Icons.graphic_eq),
      ('Cinema', Icons.movie),
      ('Podcast', Icons.podcasts),
      ('Lo-fi', Icons.album),
      ('Stage', Icons.mic_external_on),
    ];
    final picked = await _showChipSheet(
      title: 'Equalizer',
      accent: _RootTool.audio.accent,
      items: presets,
    );
    if (picked != null) _toast('EQ → $picked');
  }

  Future<void> _showDuckingSheet() async {
    const presets = <(String, IconData)>[
      ('Off', Icons.do_not_disturb_off),
      ('Light (-6 dB)', Icons.volume_down),
      ('Medium (-12 dB)', Icons.volume_mute),
      ('Strong (-18 dB)', Icons.volume_off),
      ('Auto (voice-detect)', Icons.auto_mode),
    ];
    final picked = await _showChipSheet(
      title: 'Ducking',
      accent: _RootTool.audio.accent,
      items: presets,
    );
    if (picked != null) _toast('Ducking → $picked');
  }

  Future<void> _showBeatSheet() async {
    const presets = <(String, IconData)>[
      ('Detect beats', Icons.auto_graph),
      ('Snap clips to beat', Icons.timeline),
      ('Snap captions', Icons.subtitles),
      ('Snap stickers', Icons.emoji_emotions),
      ('Clear beat markers', Icons.clear),
    ];
    final picked = await _showChipSheet(
      title: 'Beat sync',
      accent: _RootTool.audio.accent,
      items: presets,
    );
    if (picked != null) _toast('Beat → $picked');
  }

  Future<void> _showGradientSheet() async {
    const presets = <(String, IconData)>[
      ('Sunset', Icons.wb_sunny),
      ('Ocean', Icons.water),
      ('Neon', Icons.flash_on),
      ('Mono', Icons.gradient),
      ('Pride', Icons.color_lens),
      ('Rose gold', Icons.diamond),
    ];
    final picked = await _showChipSheet(
      title: 'Gradient text',
      accent: _RootTool.text.accent,
      items: presets,
    );
    if (picked != null) _toast('Gradient → $picked');
  }

  Future<void> _showWordSyncSheet() async {
    const presets = <(String, IconData)>[
      ('Highlight current', Icons.format_color_text),
      ('Pop-in per word', Icons.bubble_chart),
      ('Karaoke fill', Icons.lyrics),
      ('Bouncing dot', Icons.circle),
    ];
    final picked = await _showChipSheet(
      title: 'Word sync',
      accent: _RootTool.captions.accent,
      items: presets,
    );
    if (picked != null) _toast('Word sync → $picked');
  }

  Future<void> _showTranslateSheet() async {
    const presets = <(String, IconData)>[
      ('English', Icons.language),
      ('Spanish', Icons.language),
      ('Hindi', Icons.language),
      ('Japanese', Icons.language),
      ('French', Icons.language),
      ('Portuguese', Icons.language),
    ];
    final picked = await _showChipSheet(
      title: 'Translate captions',
      accent: _RootTool.captions.accent,
      items: presets,
    );
    if (picked != null) _toast('Translate → $picked');
  }

  Future<void> _showPacksSheet() async {
    const presets = <(String, IconData)>[
      ('Pop', Icons.celebration),
      ('Memes', Icons.tag_faces),
      ('Anime', Icons.face),
      ('Holidays', Icons.event),
      ('Animated', Icons.movie),
      ('Pro packs', Icons.workspace_premium),
    ];
    final picked = await _showChipSheet(
      title: 'Sticker packs',
      accent: _RootTool.stickers.accent,
      items: presets,
    );
    if (picked != null) _toast('Pack → $picked');
  }

  Future<void> _showArSheet() async {
    const presets = <(String, IconData)>[
      ('Face mask', Icons.face),
      ('Glasses', Icons.visibility),
      ('Hat', Icons.emoji_people),
      ('Body track', Icons.directions_run),
      ('Hand track', Icons.back_hand),
    ];
    final picked = await _showChipSheet(
      title: 'AR stickers',
      accent: _RootTool.stickers.accent,
      items: presets,
    );
    if (picked != null) _toast('AR → $picked');
  }

  Future<void> _showTransitionsSheet() async {
    const presets = <(String, IconData)>[
      ('Cut', Icons.content_cut),
      ('Fade', Icons.gradient),
      ('Slide', Icons.swap_horiz),
      ('Zoom', Icons.zoom_in),
      ('Whip', Icons.rotate_right),
      ('Glitch', Icons.broken_image),
      ('Flash', Icons.flash_on),
      ('Spin', Icons.refresh),
    ];
    final picked = await _showChipSheet(
      title: 'Transitions',
      accent: _RootTool.video.accent,
      items: presets,
    );
    if (picked != null) _toast('Transition → $picked');
  }

  Future<String?> _showChipSheet({
    required String title,
    required Color accent,
    required List<(String, IconData)> items,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: kBgBlack,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ChipPickerSheet(
        title: title,
        accent: accent,
        items: items,
      ),
    );
  }
}

// ─── Snapshot for undo ────────────────────────────────────────────

class EditorSnapshot {
  final String label;
  final AspectMode aspect;
  final BackgroundMode bgMode;
  final Color bgColor;
  final String? bgImagePath;
  final FilterPreset filter;
  final double filterIntensity;
  final EditorAdjust adjust;
  final bool clipMuted;
  final double clipSpeed;
  final int coverMs;
  final List<ClipSegment> clips;
  final List<TextOverlay> texts;
  final List<StickerOverlay> stickers;
  final List<DrawStroke> strokes;
  final List<AudioTrack> audios;
  final List<Caption> captions;

  EditorSnapshot._({
    required this.label,
    required this.aspect,
    required this.bgMode,
    required this.bgColor,
    required this.bgImagePath,
    required this.filter,
    required this.filterIntensity,
    required this.adjust,
    required this.clipMuted,
    required this.clipSpeed,
    required this.coverMs,
    required this.clips,
    required this.texts,
    required this.stickers,
    required this.strokes,
    required this.audios,
    required this.captions,
  });

  factory EditorSnapshot.from(EditorState s, String label) {
    return EditorSnapshot._(
      label: label,
      aspect: s.aspect,
      bgMode: s.bgMode,
      bgColor: s.bgColor,
      bgImagePath: s.bgImagePath,
      filter: s.filter,
      filterIntensity: s.filterIntensity,
      adjust: EditorAdjust(
        brightness: s.adjust.brightness,
        contrast: s.adjust.contrast,
        saturation: s.adjust.saturation,
        brilliance: s.adjust.brilliance,
        sharpen: s.adjust.sharpen,
        clarity: s.adjust.clarity,
        temperature: s.adjust.temperature,
        tint: s.adjust.tint,
        vibrance: s.adjust.vibrance,
      ),
      clipMuted: s.clipMuted,
      clipSpeed: s.clipSpeed,
      coverMs: s.coverMs,
      clips: List.of(s.clips),
      texts: List.of(s.texts),
      stickers: List.of(s.stickers),
      strokes: List.of(s.strokes),
      audios: List.of(s.audios),
      captions: List.of(s.captions),
    );
  }

  void applyTo(EditorState s) {
    s.aspect = aspect;
    s.bgMode = bgMode;
    s.bgColor = bgColor;
    s.bgImagePath = bgImagePath;
    s.filter = filter;
    s.filterIntensity = filterIntensity;
    s.adjust = adjust;
    s.clipMuted = clipMuted;
    s.clipSpeed = clipSpeed;
    s.coverMs = coverMs;
    s.clips
      ..clear()
      ..addAll(clips);
    s.texts
      ..clear()
      ..addAll(texts);
    s.stickers
      ..clear()
      ..addAll(stickers);
    s.strokes
      ..clear()
      ..addAll(strokes);
    s.audios
      ..clear()
      ..addAll(audios);
    s.captions
      ..clear()
      ..addAll(captions);
  }
}

// ─── Layout pieces ────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.resolution,
    required this.onClose,
    required this.onSearch,
    required this.onResolution,
    required this.onExport,
    required this.aspect,
    required this.onAspect,
    required this.savedFlash,
    required this.onReset,
  });
  final int resolution;
  final VoidCallback onClose;
  final VoidCallback onSearch;
  final VoidCallback onResolution;
  final VoidCallback onExport;
  final AspectMode aspect;
  final ValueChanged<AspectMode> onAspect;
  final bool savedFlash;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      color: kBgBlack,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          GestureDetector(
            onLongPress: onReset,
            child: IconButton(
              onPressed: onClose,
              tooltip: 'Close · long-press: reset all',
              icon: const Icon(Icons.close,
                  color: Colors.white, semanticLabel: 'Close'),
            ),
          ),
          if (savedFlash)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              builder: (_, v, child) {
                return Opacity(
                  opacity: v,
                  child: Transform.scale(scale: 0.8 + 0.2 * v, child: child),
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.check_circle, color: kAccentCyan, size: 14),
                  SizedBox(width: 4),
                  Text('Saved',
                      style: TextStyle(color: kAccentCyan, fontSize: 11)),
                ],
              ),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final preset in const [
                    (AspectMode.r9x16, '9:16'),
                    (AspectMode.r1x1, '1:1'),
                    (AspectMode.r16x9, '16:9'),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: InkWell(
                        onTap: () => onAspect(preset.$1),
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: aspect == preset.$1
                                ? kAccentCyan
                                : kBgSurface,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            preset.$2,
                            style: TextStyle(
                              color: aspect == preset.$1
                                  ? Colors.black
                                  : Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onResolution();
            },
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: kBgSurface,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${resolution}P',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2)),
                  const SizedBox(width: 4),
                  const Icon(Icons.keyboard_arrow_down,
                      color: Colors.white, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              onExport();
            },
            style: FilledButton.styleFrom(
              backgroundColor: kAccentCyan,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
            ),
            child: const Text('Export',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    letterSpacing: 0.2)),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
            tooltip: 'More',
            color: kBgSurface,
            onSelected: (v) {
              if (v == 'reset') onReset();
              if (v == 'search') onSearch();
              if (v == 'resolution') onResolution();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'search',
                child: Text('Search assets',
                    style: TextStyle(color: Colors.white)),
              ),
              PopupMenuItem(
                value: 'resolution',
                child: Text('Export settings',
                    style: TextStyle(color: Colors.white)),
              ),
              PopupMenuItem(
                value: 'reset',
                child: Text('Reset all edits',
                    style: TextStyle(color: Color(0xFFE53935))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewArea extends StatefulWidget {
  const _PreviewArea({
    required this.state,
    required this.controller,
    required this.onEditOverlayText,
    required this.onToast,
    required this.onReplaceSticker,
    required this.onTogglePlay,
    required this.onSkipSeconds,
  });
  final EditorState state;
  final VideoPlayerController? controller;
  final Future<void> Function(TextOverlay) onEditOverlayText;
  final void Function(String) onToast;
  final Future<void> Function(StickerOverlay) onReplaceSticker;
  final VoidCallback onTogglePlay;
  final void Function(int seconds) onSkipSeconds;

  @override
  State<_PreviewArea> createState() => _PreviewAreaState();
}

class _PreviewAreaState extends State<_PreviewArea> {
  bool _guideX = false;
  bool _guideY = false;
  bool _prevGuideX = false;
  bool _prevGuideY = false;

  void _updateGuides(double dx, double dy) {
    // dx, dy are normalized center positions [0..1]
    const tol = 0.04;
    final gx = (dx - 0.5).abs() < tol;
    final gy = (dy - 0.5).abs() < tol;
    if (gx != _guideX || gy != _guideY) {
      if ((gx && !_prevGuideX) || (gy && !_prevGuideY)) {
        HapticFeedback.selectionClick();
      }
      _prevGuideX = _guideX;
      _prevGuideY = _guideY;
      setState(() {
        _guideX = gx;
        _guideY = gy;
      });
    }
  }

  void _clearGuides() {
    if (_guideX || _guideY) {
      setState(() {
        _guideX = false;
        _guideY = false;
        _prevGuideX = false;
        _prevGuideY = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final controller = widget.controller;
    return LayoutBuilder(
      builder: (context, c) {
        final ar = state.aspect.ratio;
        final maxW = c.maxWidth;
        final maxH = c.maxHeight;
        double w, h;
        if (ar == 0) {
          final video = controller?.value.size ?? const Size(9, 16);
          final vAr = video.width == 0 ? 9 / 16 : video.width / video.height;
          if (vAr > maxW / maxH) {
            w = maxW;
            h = w / vAr;
          } else {
            h = maxH;
            w = h * vAr;
          }
        } else {
          if (ar > maxW / maxH) {
            w = maxW;
            h = w / ar;
          } else {
            h = maxH;
            w = h * ar;
          }
        }
        return Center(
          child: SizedBox(
            width: w,
            height: h,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (state.selectedOverlayId != null) {
                  state.selectedOverlayId = null;
                  state.notify();
                  return;
                }
                widget.onTogglePlay();
              },
              onDoubleTapDown: (d) {
                // ±10s skip based on which side of preview was tapped.
                final cx = d.localPosition.dx;
                widget.onSkipSeconds(cx < w / 2 ? -10 : 10);
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _BgLayer(state: state),
                  if (controller != null &&
                      controller.value.isInitialized &&
                      !state.videoHidden)
                    ColorFiltered(
                      colorFilter: buildColorFilter(state),
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: controller.value.size.width *
                              (state.proxyMode ? 0.5 : 1.0),
                          height: controller.value.size.height *
                              (state.proxyMode ? 0.5 : 1.0),
                          child: VideoPlayer(
                            controller,
                            key: const ValueKey('edit-preview-video'),
                          ),
                        ),
                      ),
                    ),
                  RepaintBoundary(child: _StrokesLayer(state: state)),
                  if (!state.stickersHidden)
                    RepaintBoundary(
                      child: _StickersLayer(
                        state: state,
                        onDragGuides: _updateGuides,
                        onDragEnd: _clearGuides,
                        onToast: widget.onToast,
                        onReplace: widget.onReplaceSticker,
                      ),
                    ),
                  RepaintBoundary(
                    child: _TextsLayer(
                      state: state,
                      onDragGuides: _updateGuides,
                      onDragEnd: _clearGuides,
                      onEditText: widget.onEditOverlayText,
                      onToast: widget.onToast,
                    ),
                  ),
                  if (!state.captionsHidden)
                    RepaintBoundary(child: _CaptionsLayer(state: state)),
                  IgnorePointer(
                    child: CustomPaint(
                      size: Size(w, h),
                      painter: _MotionPathPainter(state: state),
                    ),
                  ),
                  if (state.snapEnabled && (_guideX || _guideY))
                    IgnorePointer(
                      child: CustomPaint(
                        size: Size(w, h),
                        painter: _SnapGuidePainter(
                          showVertical: _guideX,
                          showHorizontal: _guideY,
                        ),
                      ),
                    ),
                  if (state.transformMode)
                    const Positioned(
                      left: 0,
                      right: 0,
                      top: 16,
                      child: Center(
                        child: _TransformHint(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MotionPathPainter extends CustomPainter {
  _MotionPathPainter({required this.state});
  final EditorState state;
  @override
  void paint(Canvas canvas, Size size) {
    final selId = state.selectedOverlayId;
    if (selId == null) return;
    TextOverlay? t;
    for (final e in state.texts) {
      if (e.id == selId) {
        t = e;
        break;
      }
    }
    if (t == null || t.endPosition == null) return;
    final s = Offset(t.position.dx * size.width, t.position.dy * size.height);
    final e = Offset(t.endPosition!.dx * size.width,
        t.endPosition!.dy * size.height);
    final paint = Paint()
      ..color = kAccentCyan
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    // Dashed line
    final delta = e - s;
    final dist = delta.distance;
    if (dist == 0) return;
    final dir = delta / dist;
    const dash = 6.0;
    const gap = 4.0;
    var d = 0.0;
    while (d < dist) {
      final p0 = s + dir * d;
      final p1 = s + dir * math.min(d + dash, dist);
      canvas.drawLine(p0, p1, paint);
      d += dash + gap;
    }
    // Arrowhead
    final ang = math.atan2(delta.dy, delta.dx);
    const arrow = 10.0;
    final a1 = Offset(
      e.dx - arrow * math.cos(ang - math.pi / 6),
      e.dy - arrow * math.sin(ang - math.pi / 6),
    );
    final a2 = Offset(
      e.dx - arrow * math.cos(ang + math.pi / 6),
      e.dy - arrow * math.sin(ang + math.pi / 6),
    );
    canvas.drawLine(e, a1, paint);
    canvas.drawLine(e, a2, paint);
    // Start dot
    canvas.drawCircle(s, 4, Paint()..color = kAccentCyan);
  }

  @override
  bool shouldRepaint(covariant _MotionPathPainter old) => true;
}

class _SnapGuidePainter extends CustomPainter {
  _SnapGuidePainter({required this.showVertical, required this.showHorizontal});
  final bool showVertical;
  final bool showHorizontal;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = kAccentCyan
      ..strokeWidth = 1;
    if (showVertical) {
      final x = size.width / 2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    if (showHorizontal) {
      final y = size.height / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SnapGuidePainter old) =>
      old.showVertical != showVertical || old.showHorizontal != showHorizontal;
}

class _BgLayer extends StatelessWidget {
  const _BgLayer({required this.state});
  final EditorState state;

  @override
  Widget build(BuildContext context) {
    switch (state.bgMode) {
      case BackgroundMode.none:
        return const ColoredBox(color: kBgBlack);
      case BackgroundMode.color:
        return ColoredBox(color: state.bgColor);
      case BackgroundMode.image:
        if (state.bgImagePath == null) return const ColoredBox(color: kBgBlack);
        return Image.file(File(state.bgImagePath!), fit: BoxFit.cover);
      case BackgroundMode.blur:
        return const ColoredBox(color: Color(0xFF202020));
    }
  }
}

class _TransformHint extends StatelessWidget {
  const _TransformHint();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'Use both fingers to resize your video',
        style: TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

class _TextsLayer extends StatelessWidget {
  const _TextsLayer({
    required this.state,
    this.onDragGuides,
    this.onDragEnd,
    this.onEditText,
    this.onToast,
  });
  final EditorState state;
  final void Function(double dx, double dy)? onDragGuides;
  final VoidCallback? onDragEnd;
  final Future<void> Function(TextOverlay)? onEditText;
  final void Function(String)? onToast;

  @override
  Widget build(BuildContext context) {
    final pos = state.positionMs;
    // Higher lane draws on top: sort ascending so larger lane appears later.
    final ordered = [...state.texts.where((t) => !t.hidden)]
      ..sort((a, b) => a.lane.compareTo(b.lane));
    double opacityFor(TextOverlay t) {
      const fadeMs = 300;
      final dur = t.endMs - t.startMs;
      if (dur <= 0) return 1.0;
      final fade = math.min(fadeMs, dur ~/ 3);
      if (fade <= 0) return 1.0;
      final from = (pos - t.startMs).clamp(0, fade);
      final to = (t.endMs - pos).clamp(0, fade);
      return (math.min(from, to) / fade).clamp(0.0, 1.0);
    }

    Offset positionFor(TextOverlay t) {
      if (t.endPosition == null) return t.position;
      final dur = t.endMs - t.startMs;
      if (dur <= 0) return t.position;
      final tt = ((pos - t.startMs) / dur).clamp(0.0, 1.0);
      return Offset(
        t.position.dx + (t.endPosition!.dx - t.position.dx) * tt,
        t.position.dy + (t.endPosition!.dy - t.position.dy) * tt,
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        return Stack(
          children: [
            for (final t in ordered)
              if (t.visibleAt(pos))
                Opacity(
                  opacity: opacityFor(t),
                  child: _SelectableOverlay(
                  state: state,
                  overlayId: t.id,
                  centerX: positionFor(t).dx * c.maxWidth,
                  centerY: positionFor(t).dy * c.maxHeight,
                  baseWidth: 200,
                  baseHeight: 60,
                  rotation: t.rotation,
                  scale: t.scale,
                  flipH: t.flipH,
                  onPan: (d) {
                    t.position = Offset(
                      (t.position.dx + d.delta.dx / c.maxWidth)
                          .clamp(0.0, 1.0),
                      (t.position.dy + d.delta.dy / c.maxHeight)
                          .clamp(0.0, 1.0),
                    );
                    onDragGuides?.call(t.position.dx, t.position.dy);
                    state.notify();
                  },
                  onPanEnd: onDragEnd,
                  onRotate: (d) {
                    final cx = t.position.dx * c.maxWidth;
                    final cy = t.position.dy * c.maxHeight;
                    final dx = d.globalPosition.dx - cx;
                    final dy = d.globalPosition.dy - cy;
                    t.rotation = math.atan2(dy, dx) + math.pi / 2;
                    state.notify();
                  },
                  onScaleHandle: (d) {
                    t.scale = (t.scale + d.delta.dx / 80).clamp(0.2, 5.0);
                    state.notify();
                  },
                  onClose: () {
                    state.texts.remove(t);
                    if (state.selectedOverlayId == t.id) {
                      state.selectedOverlayId = null;
                    }
                    state.notify();
                  },
                  onFlip: () {
                    t.flipH = !t.flipH;
                    state.notify();
                  },
                  onEdit: () => onEditText?.call(t),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    color: t.bgColor,
                    child: Text(
                      t.text,
                      textAlign: t.align,
                      style: TextStyle(
                        color: t.color,
                        fontSize: t.fontSize,
                        fontWeight:
                            t.bold ? FontWeight.w700 : FontWeight.w400,
                        fontStyle: t.italic
                            ? FontStyle.italic
                            : FontStyle.normal,
                        fontFamily: t.fontFamily,
                      ),
                    ),
                  ),
                ),
                ),
          ],
        );
      },
    );
  }
}

class _StickersLayer extends StatelessWidget {
  const _StickersLayer({
    required this.state,
    this.onDragGuides,
    this.onDragEnd,
    this.onToast,
    this.onReplace,
  });
  final EditorState state;
  final void Function(double dx, double dy)? onDragGuides;
  final VoidCallback? onDragEnd;
  final void Function(String)? onToast;
  final void Function(StickerOverlay)? onReplace;

  @override
  Widget build(BuildContext context) {
    final pos = state.positionMs;

    double opacityFor(StickerOverlay s) {
      const fadeMs = 300;
      final dur = s.endMs - s.startMs;
      if (dur <= 0) return 1.0;
      final fade = math.min(fadeMs, dur ~/ 3);
      if (fade <= 0) return 1.0;
      final from = (pos - s.startMs).clamp(0, fade);
      final to = (s.endMs - pos).clamp(0, fade);
      return (math.min(from, to) / fade).clamp(0.0, 1.0);
    }

    return LayoutBuilder(
      builder: (context, c) {
        return Stack(
          children: [
            for (final s in state.stickers)
              if (s.visibleAt(pos))
                Opacity(
                  opacity: opacityFor(s),
                  child: _SelectableOverlay(
                  state: state,
                  overlayId: s.id,
                  centerX: s.position.dx * c.maxWidth,
                  centerY: s.position.dy * c.maxHeight,
                  baseWidth: 120,
                  baseHeight: 120 / (s.aspect == 0 ? 1.0 : s.aspect),
                  rotation: s.rotation,
                  scale: s.scale,
                  flipH: s.flipH,
                  onPan: (d) {
                    s.position = Offset(
                      (s.position.dx + d.delta.dx / c.maxWidth)
                          .clamp(0.0, 1.0),
                      (s.position.dy + d.delta.dy / c.maxHeight)
                          .clamp(0.0, 1.0),
                    );
                    onDragGuides?.call(s.position.dx, s.position.dy);
                    state.notify();
                  },
                  onPanEnd: onDragEnd,
                  onScale: (d) {
                    s.scale = (s.scale * d.scale).clamp(0.1, 4.0);
                    state.notify();
                  },
                  onRotate: (d) {
                    final cx = s.position.dx * c.maxWidth;
                    final cy = s.position.dy * c.maxHeight;
                    final dx = d.globalPosition.dx - cx;
                    final dy = d.globalPosition.dy - cy;
                    s.rotation = math.atan2(dy, dx) + math.pi / 2;
                    state.notify();
                  },
                  onScaleHandle: (d) {
                    s.scale = (s.scale + d.delta.dx / 80).clamp(0.1, 4.0);
                    state.notify();
                  },
                  onClose: () {
                    state.stickers.remove(s);
                    if (state.selectedOverlayId == s.id) {
                      state.selectedOverlayId = null;
                    }
                    state.notify();
                  },
                  onFlip: () {
                    s.flipH = !s.flipH;
                    state.notify();
                  },
                  onEdit: () => onReplace?.call(s),
                  child: SizedBox(
                    width: 120,
                    height: 120 / (s.aspect == 0 ? 1.0 : s.aspect),
                    child: s.url.startsWith('file://')
                        ? Image.file(
                            File(s.url.replaceFirst('file://', '')),
                            fit: BoxFit.contain,
                          )
                        : Image.network(
                            s.url,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.broken_image,
                                color: Colors.red),
                          ),
                  ),
                ),
                ),
          ],
        );
      },
    );
  }
}

class _SelectableOverlay extends StatelessWidget {
  const _SelectableOverlay({
    required this.state,
    required this.overlayId,
    required this.centerX,
    required this.centerY,
    required this.baseWidth,
    required this.baseHeight,
    required this.rotation,
    required this.scale,
    required this.flipH,
    required this.onPan,
    required this.onClose,
    required this.onFlip,
    required this.onEdit,
    required this.onRotate,
    required this.onScaleHandle,
    this.onPanEnd,
    this.onScale,
    required this.child,
  });

  final EditorState state;
  final String overlayId;
  final double centerX;
  final double centerY;
  final double baseWidth;
  final double baseHeight;
  final double rotation;
  final double scale;
  final bool flipH;
  final void Function(DragUpdateDetails) onPan;
  final VoidCallback? onPanEnd;
  final void Function(ScaleUpdateDetails)? onScale;
  final VoidCallback onClose;
  final VoidCallback onFlip;
  final VoidCallback onEdit;
  final void Function(DragUpdateDetails) onRotate;
  final void Function(DragUpdateDetails) onScaleHandle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final selected = state.selectedOverlayId == overlayId;
    final w = baseWidth * scale;
    final h = baseHeight * scale;
    const pad = 8.0;
    final boxW = w + pad * 2;
    final boxH = h + pad * 2;
    return Positioned(
      left: centerX - boxW / 2,
      top: centerY - boxH / 2,
      width: boxW,
      height: boxH,
      child: Transform.rotate(
        angle: rotation,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  state.selectedOverlayId = overlayId;
                  state.notify();
                },
                onDoubleTap: onEdit,
                onScaleUpdate: (d) {
                  if (d.pointerCount > 1 || d.scale != 1.0) {
                    onScale?.call(d);
                  } else {
                    onPan(DragUpdateDetails(
                      globalPosition: d.focalPoint,
                      localPosition: d.localFocalPoint,
                      delta: d.focalPointDelta,
                    ));
                  }
                },
                onScaleEnd: onPanEnd == null ? null : (_) => onPanEnd!(),
                child: Padding(
                  padding: const EdgeInsets.all(pad),
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(
                        flipH ? -scale : scale, scale, 1.0),
                    child: Center(child: child),
                  ),
                ),
              ),
            ),
            if (selected)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: kAccentCyan, width: 1.5),
                    ),
                  ),
                ),
              ),
            if (selected) ...[
              Positioned(
                left: -12,
                top: -12,
                child: _OverlayHandle(
                  icon: Icons.close,
                  onTap: onClose,
                ),
              ),
              Positioned(
                right: -12,
                top: -12,
                child: _OverlayHandle(
                  icon: Icons.swap_horiz,
                  onTap: onFlip,
                ),
              ),
              Positioned(
                left: -12,
                bottom: -12,
                child: _OverlayHandle(
                  icon: Icons.edit,
                  onTap: onEdit,
                ),
              ),
              Positioned(
                right: -12,
                bottom: -12,
                child: _OverlayHandle(
                  icon: Icons.open_in_full,
                  onDrag: onScaleHandle,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: -36,
                child: Center(
                  child: _OverlayHandle(
                    icon: Icons.rotate_right,
                    onDrag: onRotate,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OverlayHandle extends StatelessWidget {
  const _OverlayHandle({required this.icon, this.onTap, this.onDrag});
  final IconData icon;
  final VoidCallback? onTap;
  final void Function(DragUpdateDetails)? onDrag;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onPanUpdate: onDrag,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 16, color: Colors.black),
      ),
    );
  }
}

class _StrokesLayer extends StatelessWidget {
  const _StrokesLayer({required this.state});
  final EditorState state;

  @override
  Widget build(BuildContext context) {
    if (state.strokes.isEmpty) return const SizedBox.shrink();
    return CustomPaint(painter: _StrokesPainter(state.strokes));
  }
}

class _StrokesPainter extends CustomPainter {
  _StrokesPainter(this.strokes);
  final List<DrawStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      if (s.points.length < 2) continue;
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(s.points.first.dx * size.width, s.points.first.dy * size.height);
      for (var i = 1; i < s.points.length; i++) {
        path.lineTo(
            s.points[i].dx * size.width, s.points[i].dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokesPainter old) =>
      old.strokes != strokes;
}

class _CaptionsLayer extends StatelessWidget {
  const _CaptionsLayer({required this.state});
  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final pos = state.positionMs;
    final active = state.captions
        .where((c) => pos >= c.startMs && pos <= c.endMs)
        .toList();
    if (active.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in active)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                color: Colors.black.withValues(alpha: 0.6),
                child: Text(
                  c.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PreviewControls extends StatelessWidget {
  const _PreviewControls({
    required this.isPlaying,
    required this.canUndo,
    required this.canRedo,
    required this.snapOn,
    required this.safeOn,
    required this.gridOn,
    required this.positionMs,
    required this.durationMs,
    required this.onPlay,
    required this.onPrevFrame,
    required this.onNextFrame,
    required this.onSplit,
    required this.onFullscreen,
    required this.onSnap,
    required this.onToggleSafe,
    required this.onToggleGrid,
    required this.onUndo,
    required this.onRedo,
    required this.onShowHistory,
  });
  final bool isPlaying;
  final bool canUndo;
  final bool canRedo;
  final bool snapOn;
  final bool safeOn;
  final bool gridOn;
  final int positionMs;
  final int durationMs;
  final VoidCallback onPlay;
  final VoidCallback onPrevFrame;
  final VoidCallback onNextFrame;
  final VoidCallback onSplit;
  final VoidCallback onFullscreen;
  final VoidCallback onSnap;
  final VoidCallback onToggleSafe;
  final VoidCallback onToggleGrid;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onShowHistory;

  static String _fmt(int ms) {
    final s = (ms ~/ 1000).clamp(0, 359999);
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: Colors.black.withValues(alpha: 0.55),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: LayoutBuilder(
        builder: (context, c) {
          final children = <Widget>[
            IconButton(
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onFullscreen,
              icon: const Icon(Icons.fullscreen, color: Colors.white),
            ),
            Text(
              '${_fmt(positionMs)} / ${_fmt(durationMs)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onPrevFrame,
              tooltip: 'Prev frame (←)',
              icon: const Icon(Icons.skip_previous, color: Colors.white),
            ),
            IconButton(
              iconSize: 22,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: onPlay,
              tooltip: 'Play/pause (Space)',
              icon: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
            ),
            IconButton(
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onNextFrame,
              tooltip: 'Next frame (→)',
              icon: const Icon(Icons.skip_next, color: Colors.white),
            ),
            IconButton(
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onSplit,
              tooltip: 'Split (S)',
              icon: const Icon(Icons.content_cut, color: Colors.white),
            ),
            const SizedBox(width: 8),
            _ToggleChip(
              icon: Icons.crop_free,
              active: safeOn,
              tip: 'Safe zones',
              onTap: onToggleSafe,
            ),
            _ToggleChip(
              icon: Icons.grid_on,
              active: gridOn,
              tip: 'Grid',
              onTap: onToggleGrid,
            ),
            _ToggleChip(
              icon: Icons.layers_outlined,
              active: snapOn,
              tip: 'Snap',
              onTap: onSnap,
            ),
            GestureDetector(
              onLongPress: onShowHistory,
              child: IconButton(
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: canUndo ? onUndo : null,
                tooltip: 'Undo (Z) · long-press: history',
                icon: Icon(Icons.undo,
                    color: canUndo ? Colors.white : Colors.white24),
              ),
            ),
            IconButton(
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: canRedo ? onRedo : null,
              tooltip: 'Redo (Y)',
              icon: Icon(Icons.redo,
                  color: canRedo ? Colors.white : Colors.white24),
            ),
          ];
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: SizedBox(
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  const _ToggleChip({
    required this.icon,
    required this.active,
    required this.tip,
    required this.onTap,
  });
  final IconData icon;
  final bool active;
  final String tip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Icon(icon,
              color: active ? kAccentCyan : Colors.white54, size: 18),
        ),
      ),
    );
  }
}

class _SafeZoneOverlay extends StatelessWidget {
  const _SafeZoneOverlay({required this.showSafe, required this.showGrid});
  final bool showSafe;
  final bool showGrid;
  @override
  Widget build(BuildContext context) {
    if (!showSafe && !showGrid) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: _SafePainter(showSafe: showSafe, showGrid: showGrid),
        size: Size.infinite,
      ),
    );
  }
}

class _SafePainter extends CustomPainter {
  _SafePainter({required this.showSafe, required this.showGrid});
  final bool showSafe;
  final bool showGrid;
  @override
  void paint(Canvas canvas, Size size) {
    if (showGrid) {
      final g = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 0.5;
      for (var i = 1; i < 3; i++) {
        final x = size.width * i / 3;
        final y = size.height * i / 3;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), g);
        canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
      }
    }
    if (showSafe) {
      final action = Paint()
        ..color = Colors.yellow.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      final title = Paint()
        ..color = Colors.redAccent.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      final a = Rect.fromLTWH(
          size.width * 0.05,
          size.height * 0.05,
          size.width * 0.9,
          size.height * 0.9);
      final t = Rect.fromLTWH(
          size.width * 0.1,
          size.height * 0.1,
          size.width * 0.8,
          size.height * 0.8);
      canvas.drawRect(a, action);
      canvas.drawRect(t, title);
    }
  }

  @override
  bool shouldRepaint(covariant _SafePainter old) =>
      old.showSafe != showSafe || old.showGrid != showGrid;
}

class _CommitCancelBar extends StatelessWidget {
  const _CommitCancelBar({required this.onCancel, required this.onCommit});
  final VoidCallback onCancel;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      color: kBgBlack,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          GestureDetector(
            onTap: onCancel,
            child: Container(
              width: 60,
              height: 60,
              decoration: const BoxDecoration(
                color: Color(0xFF333333),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.close, color: Colors.white, size: 28),
            ),
          ),
          GestureDetector(
            onTap: onCommit,
            child: Container(
              width: 60,
              height: 60,
              decoration: const BoxDecoration(
                color: kAccentCyan,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.check, color: Colors.black, size: 28),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionPill extends StatelessWidget {
  const _SuggestionPill({
    required this.icon,
    required this.label,
    required this.estimate,
    required this.onTap,
    required this.onDismiss,
  });
  final IconData icon;
  final String label;
  final String estimate;
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: kBgSurface,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            children: [
              Icon(icon, color: kAccentCyan, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(estimate,
                  style:
                      const TextStyle(color: kTextSecondary, fontSize: 11)),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right,
                  color: kTextSecondary, size: 16),
              const SizedBox(width: 4),
              InkWell(
                onTap: onDismiss,
                child: const Icon(Icons.close,
                    color: kTextSecondary, size: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubMenuArea extends StatelessWidget {
  const _SubMenuArea({
    required this.tool,
    required this.onBack,
    required this.onAction,
  });
  final _RootTool? tool;
  final VoidCallback onBack;
  final ValueChanged<String> onAction;

  List<_ToolEntry> _itemsFor(_RootTool t) {
    switch (t) {
      case _RootTool.video:
        return const [
          _ToolEntry('trim', Icons.content_cut, 'Trim'),
          _ToolEntry('split', Icons.cut, 'Split'),
          _ToolEntry('speed', Icons.speed, 'Speed'),
          _ToolEntry('reverse', Icons.fast_rewind, 'Reverse'),
          _ToolEntry('duplicate', Icons.copy, 'Duplicate'),
          _ToolEntry('replace', Icons.swap_horiz, 'Replace'),
          _ToolEntry('ratio', Icons.crop, 'Ratio'),
          _ToolEntry('cover', Icons.image, 'Cover'),
          _ToolEntry('background', Icons.wallpaper, 'Background'),
          _ToolEntry('mask', Icons.format_shapes, 'Mask'),
          _ToolEntry('chroma', Icons.colorize, 'Chroma'),
          _ToolEntry('stabilize', Icons.video_stable, 'Stabilize'),
          _ToolEntry('video.transitions', Icons.swap_horizontal_circle,
              'Transitions',
              badge: 'New'),
          _ToolEntry('fx.video', Icons.auto_awesome, 'Effects'),
          _ToolEntry('fx.body', Icons.face_retouching_natural, 'Body'),
          _ToolEntry('fx.photo', Icons.photo_filter, 'Photo'),
          _ToolEntry('filters.open', Icons.tune, 'Filters'),
          _ToolEntry('overlay.add', Icons.layers, 'Overlay'),
          _ToolEntry('volume', Icons.volume_up, 'Volume'),
          _ToolEntry('mute', Icons.volume_off, 'Mute'),
          _ToolEntry('delete', Icons.delete_outline, 'Delete'),
        ];
      case _RootTool.audio:
        return const [
          _ToolEntry('audio.sounds', Icons.library_music, 'Music',
              badge: 'Pro'),
          _ToolEntry('audio.sfx', Icons.surround_sound, 'SFX'),
          _ToolEntry('audio.record', Icons.mic, 'Voiceover'),
          _ToolEntry('audio.extract', Icons.audiotrack, 'Extract'),
          _ToolEntry('audio.tts', Icons.record_voice_over, 'TTS'),
          _ToolEntry('audio.fade', Icons.graphic_eq, 'Fade'),
          _ToolEntry('audio.ducking', Icons.tune, 'Ducking', badge: 'New'),
          _ToolEntry('audio.eq', Icons.equalizer, 'EQ'),
          _ToolEntry('audio.beat', Icons.timeline, 'Beat sync',
              badge: 'New'),
          _ToolEntry('audio.denoise', Icons.noise_control_off, 'Denoise'),
          _ToolEntry('audio.copyright', Icons.verified, 'Copyright'),
        ];
      case _RootTool.text:
        return const [
          _ToolEntry('text.add', Icons.add_box, 'Add text'),
          _ToolEntry('text.template', Icons.title, 'Templates'),
          _ToolEntry('text.anim', Icons.animation, 'Animation'),
          _ToolEntry('text.kinetic', Icons.motion_photos_on, 'Kinetic',
              badge: 'New'),
          _ToolEntry('text.gradient', Icons.gradient, 'Gradient'),
          _ToolEntry('text.draw', Icons.brush, 'Draw'),
          _ToolEntry('text.tts', Icons.record_voice_over, 'To audio'),
          _ToolEntry('text.lyrics', Icons.lyrics, 'Auto lyrics'),
        ];
      case _RootTool.captions:
        return const [
          _ToolEntry('cap.auto', Icons.auto_mode, 'Auto STT', badge: 'Pro'),
          _ToolEntry('cap.enter', Icons.subtitles, 'Manual'),
          _ToolEntry('cap.template', Icons.style, 'Templates'),
          _ToolEntry('cap.wordsync', Icons.play_circle, 'Word sync',
              badge: 'New'),
          _ToolEntry('cap.multilang', Icons.translate, 'Translate'),
          _ToolEntry('cap.lyrics', Icons.lyrics, 'Auto lyrics'),
          _ToolEntry('cap.import', Icons.file_download, 'Import'),
        ];
      case _RootTool.stickers:
        return const [
          _ToolEntry('sticker.emoji', Icons.emoji_emotions, 'Emoji'),
          _ToolEntry('sticker.giphy', Icons.gif_box, 'GIPHY'),
          _ToolEntry('sticker.packs', Icons.dashboard_customize, 'Packs',
              badge: 'New'),
          _ToolEntry('sticker.search', Icons.search, 'Search'),
          _ToolEntry('sticker.ar', Icons.face, 'AR', badge: 'Pro'),
          _ToolEntry('sticker.recent', Icons.history, 'Recent'),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) {
          final slide = Tween<Offset>(
            begin: const Offset(0, 0.15),
            end: Offset.zero,
          ).animate(anim);
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(position: slide, child: child),
          );
        },
        child: tool == null
            ? const SizedBox.shrink(key: ValueKey('empty'))
            : _buildPanel(tool!),
      ),
    );
  }

  Widget _buildPanel(_RootTool t) {
    final items = _itemsFor(t);
    final accent = t.accent;
    return Container(
      key: ValueKey(t),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0.05),
            kBgBlack,
          ],
        ),
        border: const Border(
          top: BorderSide(color: Colors.white12, width: 0.5),
          bottom: BorderSide(color: Colors.white10, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row.
          SizedBox(
            height: 26,
            child: Row(
              children: [
                InkWell(
                  onTap: onBack,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chevron_left, color: accent, size: 16),
                        const SizedBox(width: 2),
                        Text(
                          _labelFor(t).toUpperCase(),
                          style: TextStyle(
                            color: accent,
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${items.length} tools',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
          // Tool chips.
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => _ToolChip(
                entry: items[i],
                accent: accent,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onAction(items[i].action);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _labelFor(_RootTool t) {
    switch (t) {
      case _RootTool.video:
        return 'Video';
      case _RootTool.audio:
        return 'Audio';
      case _RootTool.text:
        return 'Text';
      case _RootTool.captions:
        return 'Captions';
      case _RootTool.stickers:
        return 'Stickers';
    }
  }
}

class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.entry,
    required this.accent,
    required this.onTap,
  });
  final _ToolEntry entry;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 68,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accent.withValues(alpha: 0.18),
                        accent.withValues(alpha: 0.06),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.25),
                      width: 0.8,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(entry.icon, color: Colors.white, size: 22),
                ),
                if (entry.badge != null)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.5),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: Text(
                        entry.badge!,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              entry.label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChipPickerSheet extends StatelessWidget {
  const _ChipPickerSheet({
    required this.title,
    required this.accent,
    required this.items,
  });
  final String title;
  final Color accent;
  final List<(String, IconData)> items;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              accent.withValues(alpha: 0.08),
              kBgBlack,
            ],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 6,
                  height: 18,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                Text(
                  '${items.length} options',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (label, icon) in items)
                  InkWell(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.of(context).pop(label);
                    },
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            accent.withValues(alpha: 0.18),
                            accent.withValues(alpha: 0.05),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 18, color: accent),
                          const SizedBox(width: 8),
                          Text(
                            label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolEntry {
  final String action;
  final IconData icon;
  final String label;
  final String? badge;
  const _ToolEntry(this.action, this.icon, this.label, {this.badge});
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.active, required this.onTap});
  final _RootTool? active;
  final ValueChanged<_RootTool> onTap;

  @override
  Widget build(BuildContext context) {
    final items = const [
      (_RootTool.video, Icons.movie_creation_outlined, 'Video'),
      (_RootTool.audio, Icons.music_note, 'Audio'),
      (_RootTool.text, Icons.text_fields, 'Text'),
      (_RootTool.captions, Icons.closed_caption, 'Captions'),
      (_RootTool.stickers, Icons.emoji_emotions_outlined, 'Stickers'),
    ];
    return Container(
      height: 68,
      decoration: const BoxDecoration(
        color: kBgBlack,
        border: Border(
          top: BorderSide(color: Colors.white12, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            for (final it in items)
              Expanded(
                child: _BottomNavCell(
                  tool: it.$1,
                  icon: it.$2,
                  label: it.$3,
                  isActive: active == it.$1,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onTap(it.$1);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomNavCell extends StatelessWidget {
  const _BottomNavCell({
    required this.tool,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });
  final _RootTool tool;
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = tool.accent;
    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: isActive ? 40 : 32,
              height: 32,
              decoration: BoxDecoration(
                color: isActive ? accent.withValues(alpha: 0.16) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: isActive ? 22 : 20,
                color: isActive ? accent : Colors.white70,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isActive ? accent : Colors.white60,
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenPreview extends StatefulWidget {
  const _FullscreenPreview({required this.controller});
  final VideoPlayerController controller;
  @override
  State<_FullscreenPreview> createState() => _FullscreenPreviewState();
}

class _FullscreenPreviewState extends State<_FullscreenPreview> {
  bool _hudVisible = true;
  Timer? _hudTimer;

  @override
  void initState() {
    super.initState();
    _bumpHud();
  }

  void _bumpHud() {
    _hudTimer?.cancel();
    setState(() => _hudVisible = true);
    _hudTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  @override
  void dispose() {
    _hudTimer?.cancel();
    super.dispose();
  }

  String _fmt(int ms) {
    final s = (ms ~/ 1000).clamp(0, 359999);
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _bumpHud,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio:
                    c.value.aspectRatio == 0 ? 9 / 16 : c.value.aspectRatio,
                child: VideoPlayer(
                  c,
                  key: const ValueKey('fullscreen-preview-video'),
                ),
              ),
            ),
            AnimatedOpacity(
              opacity: _hudVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: SafeArea(
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.fullscreen_exit,
                              color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const Spacer(),
                      ],
                    ),
                    const Spacer(),
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: c,
                      builder: (_, v, __) => Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                v.isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                                size: 28,
                              ),
                              onPressed: () {
                                v.isPlaying ? c.pause() : c.play();
                                _bumpHud();
                              },
                            ),
                            Text(_fmt(v.position.inMilliseconds),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ])),
                            Expanded(
                              child: Slider(
                                value: v.position.inMilliseconds
                                    .toDouble()
                                    .clamp(0,
                                        v.duration.inMilliseconds.toDouble()),
                                min: 0,
                                max: v.duration.inMilliseconds
                                    .toDouble()
                                    .clamp(1, double.infinity),
                                activeColor: kAccentCyan,
                                onChanged: (val) {
                                  c.seekTo(Duration(milliseconds: val.toInt()));
                                  _bumpHud();
                                },
                              ),
                            ),
                            Text(_fmt(v.duration.inMilliseconds),
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontFeatures: [
                                      FontFeature.tabularFigures()
                                    ])),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportBusy extends StatelessWidget {
  const _ExportBusy({this.label, this.pct, this.onCancel});
  final String? label;
  final double? pct;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xCC000000),
      child: Center(
        child: Container(
          width: 260,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          decoration: BoxDecoration(
            color: kBgSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pct == null)
                const CircularProgressIndicator(color: kAccentCyan)
              else ...[
                LinearProgressIndicator(
                  value: pct,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(kAccentCyan),
                  minHeight: 6,
                ),
                const SizedBox(height: 6),
                Text(
                  '${(pct! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (label != null)
                Text(label!,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              if (onCancel != null) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: const Color(0xFF333333),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 8),
                  ),
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingOverlay extends StatefulWidget {
  const _OnboardingOverlay({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  State<_OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends State<_OnboardingOverlay> {
  int _step = 0;
  static const _tips = <(IconData, String, String)>[
    (Icons.play_circle, 'Preview',
        'Space or play button to start. Tap inside the preview to focus.'),
    (Icons.timeline, 'Timeline',
        'Drag clips, text and audio. Pinch to zoom. Long-press blank area to scrub.'),
    (Icons.tune, 'Tools',
        'Bottom bar opens edits, audio, text, effects, captions and filters.'),
  ];

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = _tips[_step];
    final isLast = _step == _tips.length - 1;
    return ColoredBox(
      color: const Color(0xC0000000),
      child: Center(
        child: Container(
          width: 280,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: kBgSurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kAccentCyan, width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: kAccentCyan, size: 36),
              const SizedBox(height: 10),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _tips.length; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _step ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _step ? kAccentCyan : Colors.white24,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: widget.onDismiss,
                    child: const Text('Skip',
                        style: TextStyle(color: Colors.white54)),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      if (isLast) {
                        widget.onDismiss();
                      } else {
                        setState(() => _step++);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kAccentCyan,
                      foregroundColor: Colors.black,
                    ),
                    child: Text(isLast ? 'Got it' : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutsOverlay extends StatelessWidget {
  const _ShortcutsOverlay({required this.onDismiss});
  final VoidCallback onDismiss;

  static const _rows = <(String, String)>[
    ('Space', 'Play / Pause'),
    ('← / →', 'Step frame'),
    (', / .', 'Prev / next clip edge'),
    ('J / L', 'Shuttle slower / faster'),
    ('K', 'Stop shuttle (1×)'),
    ('1-5', 'Speed: ¼× ½× 1× 2× 4×'),
    ('I / O', 'Mark loop IN / OUT'),
    ('[ / ]', 'Toggle / clear loop'),
    ('S', 'Split at playhead'),
    ('D', 'Duplicate selected'),
    ('C / V', 'Copy / paste selected'),
    ('Delete', 'Delete selected'),
    ('Z / Y', 'Undo / redo'),
    ('? / /', 'Toggle this sheet'),
  ];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      child: ColoredBox(
        color: const Color(0xC0000000),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: kBgSurface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kAccentCyan, width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.keyboard, color: kAccentCyan, size: 22),
                    const SizedBox(width: 8),
                    const Text('Shortcuts',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white54, size: 18),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      onPressed: onDismiss,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final r in _rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 80,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF333333),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(r.$1,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                )),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(r.$2,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              )),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                const Text(
                  'Long-press undo for history list',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LoopPill extends StatelessWidget {
  const _LoopPill({
    required this.inMs,
    required this.outMs,
    required this.enabled,
    required this.fmt,
  });

  final int? inMs;
  final int? outMs;
  final bool enabled;
  final String Function(int) fmt;

  @override
  Widget build(BuildContext context) {
    final accent = enabled ? kAccentCyan : const Color(0xFFFFA726);
    final inLabel = inMs == null ? '—' : fmt(inMs!);
    final outLabel = outMs == null ? '—' : fmt(outMs!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(enabled ? Icons.loop : Icons.repeat,
              color: accent, size: 16),
          const SizedBox(width: 6),
          Text(
            '$inLabel → $outLabel',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (!enabled) ...[
            const SizedBox(width: 6),
            const Text(
              'OFF',
              style: TextStyle(
                color: Colors.white54,
                fontWeight: FontWeight.w700,
                fontSize: 10,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ShuttlePill extends StatelessWidget {
  const _ShuttlePill({required this.rate});
  final double rate;

  String get _label {
    if (rate == rate.roundToDouble()) {
      return '${rate.toInt()}×';
    }
    final s = rate.toStringAsFixed(2);
    final trimmed = s.endsWith('0') ? s.substring(0, s.length - 1) : s;
    return '$trimmed×';
  }

  IconData get _icon {
    if (rate > 1.0) return Icons.fast_forward_rounded;
    if (rate < 1.0) return Icons.slow_motion_video_rounded;
    return Icons.play_arrow_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kAccentCyan, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, color: kAccentCyan, size: 16),
          const SizedBox(width: 6),
          Text(
            _label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
