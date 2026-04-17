import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'package:loopit_minis/src/independent/camera_plugin_minis_engine.dart';
import 'package:loopit_minis/src/independent/minis_gallery_preview.dart';
import 'package:loopit_minis/src/independent/minis_video_duration.dart';
import 'package:loopit_minis/src/independent/minis_multiclip_merge.dart';
import 'package:loopit_minis/src/independent/minis_music_segment.dart';
import 'package:loopit_minis/src/independent/minis_music_trim_sheet.dart';
import 'package:loopit_minis/src/independent/minis_recording_clip.dart';
import 'package:loopit_minis/src/independent/minis_recording_ring_painter.dart';
import 'package:loopit_minis/src/independent/minis_reel_clip_trimmer_page.dart';
import 'package:loopit_minis/src/independent/minis_video_file_ready.dart';
import 'package:loopit_minis/src/independent/minis_video_preview_page.dart';
import 'package:loopit_minis/src/native_video_trim_user_message.dart'
    show logVideoTrimDiagnostic, messageForVideoTrimFailure;
import 'package:loopit_minis/src/session_and_toast.dart';
import 'package:loopit_minis/src/minis_capture_host.dart';
import 'package:loopit_minis/src/minis_capture_ports.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Countdown before a **photo** is taken (self-timer). Video uses press-and-hold.
enum MinisRecordCountdownMode {
  /// Take a photo as soon as you release a short tap.
  off,

  /// 3 second delay before the shutter fires.
  three,

  /// 10 second delay before the shutter fires.
  ten,
}

/// Full-screen Minis-style capture using only [MinisCameraEnginePort] (default:
/// [CameraPluginMinisEngine], no Retrytech).
///
/// **Hold** the shutter to record video; **short tap** takes a photo unless
/// **videoOnly** is set (host “Minis / reel” flows — video only). While
/// recording, **swipe up/down on the preview** to zoom in/out (device support
/// via [MinisCameraEnginePort] zoom). Each
/// completed video (release after hold) **appends** a segment (LoopIt-style
/// multi-clip reel) until you tap the checkmark to **merge** segments with
/// [pro_video_editor]. **Gallery** uses [ImagePicker.pickMedia]; with recorded
/// segments the bottom-left shows **gallery** and **remove last clip** side by
/// side. **Sounds** uses [FilePicker] for audio on device; the
/// chosen track is **mixed in** when you confirm (merge / export). After
/// picking a file, a trim sheet ([showMinisMusicTimingSheet]) lets you choose a
/// section (via [audio_waveforms]); on **Android / iOS** that section also
/// **plays during hold-to-record** as a guide. Long-press **Sounds** to clear.
///
/// On **web**, shows an unsupported message (camera plugin is mobile-focused).
class MinisIndependentCaptureScreen extends StatefulWidget {
  const MinisIndependentCaptureScreen({
    super.key,
    this.engine,
    this.permissionPolicy = MinisCapturePermissionPolicy.request,
    this.maxRecordingDuration = const Duration(seconds: 60),
    this.onClipConfirmed,
    this.initialMusicPath,
    this.initialMusicStartMs = 0,
    this.initialMusicEndMs,
    this.videoOnly = false,
  });

  /// If null, a [CameraPluginMinisEngine] is created and disposed by this
  /// widget. If you pass a custom engine, you must dispose it yourself when
  /// not using the default lifecycle (this widget only disposes engines it creates).
  final MinisCameraEnginePort? engine;

  final MinisCapturePermissionPolicy permissionPolicy;

  /// Total reel cap: sum of all segment wall-clock times (plus the segment
  /// currently recording) must stay within this budget (speed-adjusted like
  /// the on-screen label).
  final Duration maxRecordingDuration;

  /// When the user taps the checkmark after a capture (photo or video).
  /// If null and [Navigator.canPop] is true, [Navigator.pop] is called with the
  /// path; otherwise the file is copied under app documents (`minis_captures`).
  final ValueChanged<String>? onClipConfirmed;

  /// Optional preselected music file path (host-provided) used to seed the
  /// minis music rail for flows like "make mini from this audio".
  final String? initialMusicPath;

  /// Optional start offset for [initialMusicPath].
  final int initialMusicStartMs;

  /// Optional end offset for [initialMusicPath]. If null, defaults to session cap.
  final int? initialMusicEndMs;

  /// When true (e.g. **Minis / reel** entry from the host), disables short-tap
  /// photo capture and still-image picks from the gallery; only video is
  /// allowed. Story and feed flows pass `false` so photo + video both work.
  final bool videoOnly;

  @override
  State<MinisIndependentCaptureScreen> createState() =>
      _MinisIndependentCaptureScreenState();
}

bool _pickedXFileIsVideo(XFile x) {
  final mt = x.mimeType?.toLowerCase();
  if (mt != null && mt.startsWith('video/')) return true;
  final path = x.path.toLowerCase();
  const v = ['.mp4', '.mov', '.m4v', '.webm', '.mkv', '.3gp'];
  for (final ext in v) {
    if (path.endsWith(ext)) return true;
  }
  return false;
}

class _MinisIndependentCaptureScreenState
    extends State<MinisIndependentCaptureScreen> with TickerProviderStateMixin {
  static const double _kRailIconSize = 25;
  static const double _kCornerBtnSize = 48;
  static const double _kCornerIconSize = 22;
  static const double _kAppBarIconSize = 26;
  static const double _kStatusPillIconSize = 17;
  static const double _kRailChevronSize = 26;

  /// Fixed column so rail icons and labels stay visually aligned.
  static const double _kRailColumnWidth = 72;
  static const double _kRailIconSlotHeight = 28;
  static const double _kRailLabelSlotHeight = 32;
  static const double _kShutterOuter = 92;
  static const double _kShutterInner = 72;
  static const double _kRecordingRingStroke = 4;
  static const double _kShutterStopIconSize = 34;

  void _logGuideAudio(String message) {
    debugPrint('MINIS_GUIDE_AUDIO: $message');
  }

  /// Filter Android/iOS logs with: `adb logcat | grep MINIS_MULTICLIP`
  void _logMulticlip(String message) {
    debugPrint('MINIS_MULTICLIP: $message');
  }

  void _logMulticlipState(String tag) {
    final rem = _sessionCapMs - _clipsTotalDurationMs - _liveClipElapsedMs;
    _logMulticlip(
      '$tag | clips=${_videoClips.length} usedMs=$_clipsTotalDurationMs '
      'capMs=$_sessionCapMs remainingMs=${rem.clamp(0, 1 << 30)} '
      'liveRecMs=$_liveClipElapsedMs speed=$_speedRailLabel '
      'speedIdx=$_speedIndex maxRecWidgetSec=${widget.maxRecordingDuration.inSeconds} '
      'mounted=$mounted busy=$_busy recording=$_recording videoOnly=${widget.videoOnly}',
    );
  }

  MinisCameraEnginePort? _engine;
  bool _ownEngine = false;
  bool _webUnsupported = false;
  bool _permissionDenied = false;
  bool _busy = true;
  String? _error;
  bool _recording = false;
  String? _lastCapturePath;
  bool _lastCaptureIsVideo = false;
  bool _micEnabled = true;
  bool _railExpanded = true;
  MinisRecordCountdownMode _countdownMode = MinisRecordCountdownMode.three;
  bool _countingDown = false;
  int? _countdownTick;
  Timer? _maxRecordTimer;
  Timer? _holdStartTimer;
  bool _shutterFingerDown = false;
  bool _holdVideoArmed = false;
  MinisMusicSegment? _musicSegment;
  PlayerController? _musicGuidePlayer;
  StreamSubscription<int>? _musicGuidePosSub;
  bool _guideStartInProgress = false;
  static const List<double> _speedSteps = [0.5, 1.0, 1.5, 2.0, 3.0];
  int _speedIndex = 1;

  /// Appended video segments (camera hold-to-record or gallery video).
  final List<MinisRecordingClip> _videoClips = [];
  int _clipsTotalDurationMs = 0;
  DateTime? _activeClipStartedAt;
  int _clipBudgetMsAtRecordStart = 0;
  Timer? _clipElapsedTicker;

  /// Cached while recording (from [MinisCameraEnginePort] zoom APIs).
  double _zoomMin = 1.0;
  double _zoomMax = 1.0;
  double _zoomLevel = 1.0;
  int? _zoomGesturePointer;
  double _zoomPanStartY = 0;
  double _zoomPanStartLevel = 1.0;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _webUnsupported = true;
      _busy = false;
      return;
    }
    if (widget.engine != null) {
      _engine = widget.engine;
    } else {
      _engine = CameraPluginMinisEngine();
      _ownEngine = true;
    }
    _boot();
  }

  Future<void> _boot() async {
    if (_webUnsupported) return;

    if (widget.permissionPolicy == MinisCapturePermissionPolicy.request) {
      final cam = await Permission.camera.request();
      final mic = await Permission.microphone.request();
      if (!cam.isGranted || !mic.isGranted) {
        if (mounted) {
          setState(() {
            _permissionDenied = true;
            _busy = false;
          });
        }
        return;
      }
    }

    try {
      await _engine!.initialize();
      if (mounted) setState(() => _busy = false);
      await _applyInitialMusicPrefillIfAny();
    } catch (e, st) {
      debugPrint('MinisIndependentCaptureScreen init failed: $e\n$st');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _busy = false;
        });
      }
    }
  }

  Future<void> _applyInitialMusicPrefillIfAny() async {
    final inputPath = widget.initialMusicPath;
    if (inputPath == null || inputPath.trim().isEmpty) return;
    final normalized = inputPath.replaceAll('\\', '/');
    final file = File(normalized);
    if (!await file.exists()) {
      debugPrint('minis: initial music file not found: $normalized');
      return;
    }
    final startMs = math.max(0, widget.initialMusicStartMs);
    final endMs = widget.initialMusicEndMs == null
        ? math.max(startMs + 1000, _sessionCapMs)
        : math.max(startMs, widget.initialMusicEndMs!);
    if (!mounted) return;
    setState(() {
      _musicSegment = MinisMusicSegment(
        path: normalized,
        startMs: startMs,
        endMs: endMs,
      );
    });
    await _prepareGuideMusic();
  }

  @override
  void dispose() {
    _maxRecordTimer?.cancel();
    _holdStartTimer?.cancel();
    _clipElapsedTicker?.cancel();
    unawaited(_disposeGuideMusic());
    if (_ownEngine) {
      unawaited(_engine?.dispose());
    }
    super.dispose();
  }

  void _toast(String msg) {
    showMinisToast(context, msg);
  }

  Future<void> _disposeGuideMusic() async {
    await _musicGuidePosSub?.cancel();
    _musicGuidePosSub = null;
    final p = _musicGuidePlayer;
    _musicGuidePlayer = null;
    if (p == null) return;
    try {
      await p.pausePlayer();
    } catch (_) {}
    try {
      await p.release();
    } catch (_) {}
  }

  Future<void> _prepareGuideMusic() async {
    await _disposeGuideMusic();
    final seg = _musicSegment;
    if (seg == null || !minisAudioWaveformsTrimSupported()) return;
    final file = File(seg.path);
    if (!await file.exists()) return;
    final p = PlayerController();
    p.overrideAudioSession = true;
    _musicGuidePlayer = p;
    try {
      _logGuideAudio(
        'prepare start: path=${seg.path} startMs=${seg.startMs} endMs=${seg.endMs}',
      );
      await p.preparePlayer(
        path: seg.path,
        shouldExtractWaveform: false,
        volume: 1.0,
      );
      await p.setFinishMode(finishMode: FinishMode.pause);
      _logGuideAudio(
        'prepare done: state=${p.playerState} maxDuration=${p.maxDuration}',
      );
    } catch (e, st) {
      _logGuideAudio('prepare failed: $e');
      debugPrint('Minis guide music prepare failed: $e\n$st');
      await _disposeGuideMusic();
      if (mounted) {
        _toast('Could not load music for recording guide.');
      }
    }
  }

  Future<void> _pauseGuideMusic() async {
    await _musicGuidePosSub?.cancel();
    _musicGuidePosSub = null;
    try {
      await _musicGuidePlayer?.pausePlayer();
    } catch (_) {}
  }

  Future<void> _guideCall(
    Future<void> Function() action, {
    required String step,
    int timeoutMs = 2200,
  }) async {
    await action().timeout(
      Duration(milliseconds: timeoutMs),
      onTimeout: () => throw TimeoutException('guide timeout at $step'),
    );
  }

  Future<void> _startGuideMusicForRecording() async {
    if (_guideStartInProgress) {
      _logGuideAudio('play ignored: start already in progress');
      return;
    }
    _guideStartInProgress = true;
    final seg = _musicSegment;
    final p = _musicGuidePlayer;
    if (seg == null || p == null || !minisAudioWaveformsTrimSupported()) {
      _guideStartInProgress = false;
      return;
    }
    await _musicGuidePosSub?.cancel();
    _musicGuidePosSub = null;
    final liveElapsedForOffset = _recording ? _liveClipElapsedMs : 0;
    final offset = seg.startMs + _clipsTotalDurationMs + liveElapsedForOffset;
    if (offset >= seg.endMs) {
      _guideStartInProgress = false;
      return;
    }
    try {
      _logGuideAudio(
        'play requested: state=${p.playerState} offset=$offset clipsTotal=$_clipsTotalDurationMs liveElapsed=$liveElapsedForOffset',
      );
      final stateBeforePlay = p.playerState;
      final shouldPrepare = stateBeforePlay.isStopped ||
          (!stateBeforePlay.isInitialised && !stateBeforePlay.isPaused);
      if (shouldPrepare) {
        _logGuideAudio('play prepare-before-start');
        await _guideCall(
          () => p.preparePlayer(
            path: seg.path,
            shouldExtractWaveform: false,
            volume: 1.0,
          ),
          step: 'prepare',
        );
        _logGuideAudio('play prepare done: state=${p.playerState}');
      }
      if (p.playerState.isPlaying) {
        _logGuideAudio('pause existing playback before restart');
        await _guideCall(() => p.pausePlayer(), step: 'pause-before-restart');
      }
      var maxDuration = p.maxDuration;
      if (maxDuration <= 0) {
        maxDuration = await p.getDuration();
      }
      final safeOffset = offset.clamp(0, math.max(0, maxDuration - 1)).toInt();
      _logGuideAudio(
        'seek/start: safeOffset=$safeOffset maxDuration=$maxDuration segEnd=${seg.endMs}',
      );
      await _guideCall(() => p.seekTo(safeOffset), step: 'seek');
      await _guideCall(() => p.startPlayer(), step: 'start');
      _logGuideAudio('start called: state=${p.playerState}');
      if (!p.playerState.isPlaying) {
        _logGuideAudio('not playing after start, hard retry');
        await _guideCall(() => p.stopPlayer(), step: 'hard-stop');
        await _guideCall(
          () => p.preparePlayer(
            path: seg.path,
            shouldExtractWaveform: false,
            volume: 1.0,
          ),
          step: 'hard-prepare',
        );
        await _guideCall(() => p.seekTo(safeOffset), step: 'hard-seek');
        await _guideCall(() => p.startPlayer(), step: 'hard-start');
        _logGuideAudio('hard retry start called: state=${p.playerState}');
      }
      _logGuideAudio('play result: state=${p.playerState}');
      _musicGuidePosSub = p.onCurrentDurationChanged.listen((pos) {
        if (pos >= seg.endMs) {
          _logGuideAudio(
              'auto pause at segment end: pos=$pos end=${seg.endMs}');
          unawaited(p.pausePlayer());
        }
      });
    } catch (e, st) {
      _logGuideAudio('play failed: $e');
      debugPrint('Minis guide music play failed: $e\n$st');
    } finally {
      _guideStartInProgress = false;
    }
  }

  Future<void> _ensureGuideMusicPlayingAfterRecordStart() async {
    if (!_recording) return;
    final p = _musicGuidePlayer;
    if (p == null) return;
    if (p.playerState.isPlaying) return;
    // Camera start can steal/settle audio focus right after record starts.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!_recording || !mounted) return;
    if (_guideStartInProgress) return;
    if (p.playerState.isPlaying) return;
    _logGuideAudio('delayed retry after record start');
    await _startGuideMusicForRecording();
  }

  Future<void> _clearMusic() async {
    if (_recording || _busy || _countingDown) return;
    await _pauseGuideMusic();
    await _disposeGuideMusic();
    if (mounted) setState(() => _musicSegment = null);
    _toast('Music cleared');
  }

  /// Short label for the right rail (single line, fixed-width column).
  String get _timerRailLabel {
    switch (_countdownMode) {
      case MinisRecordCountdownMode.off:
        return 'Off';
      case MinisRecordCountdownMode.three:
        return '3s';
      case MinisRecordCountdownMode.ten:
        return '10s';
    }
  }

  String get _speedRailLabel {
    final v = _speedSteps[_speedIndex];
    final s = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
    return '${s}x';
  }

  Duration get _effectiveMaxRecording {
    final base = widget.maxRecordingDuration.inMilliseconds;
    final mult = _speedSteps[_speedIndex];
    final ms = (base / mult).round().clamp(5000, 300000);
    return Duration(milliseconds: ms);
  }

  int get _sessionCapMs => _effectiveMaxRecording.inMilliseconds;

  int get _liveClipElapsedMs {
    if (!_recording || _activeClipStartedAt == null) return 0;
    return DateTime.now().difference(_activeClipStartedAt!).inMilliseconds;
  }

  int get _remainingSessionMs {
    return math.max(
      0,
      _sessionCapMs - _clipsTotalDurationMs - _liveClipElapsedMs,
    );
  }

  double get _recordRingProgress {
    final cap = math.max(1, _sessionCapMs);
    final used = (_clipsTotalDurationMs + (_recording ? _liveClipElapsedMs : 0))
        .clamp(0, cap);
    return used / cap;
  }

  bool get _canConfirmClip =>
      (_videoClips.isNotEmpty ||
          (_lastCapturePath != null && _lastCapturePath!.isNotEmpty)) &&
      !_recording &&
      !_countingDown &&
      !_busy;

  /// Resolves [PlatformFile] to a path the trim sheet and encoder can open.
  ///
  /// Uses the picker path when the file exists; otherwise copies from
  /// [PlatformFile.readStream] (when [FilePicker.pickFiles] used
  /// `withReadStream: true`) or from [PlatformFile.bytes].
  Future<String?> _materializePickedAudioForTrim(PlatformFile file) async {
    final path = file.path;
    if (path != null && path.isNotEmpty) {
      try {
        if (await File(path).exists()) {
          return path.replaceAll('\\', '/');
        }
      } catch (_) {}
    }
    final stream = file.readStream;
    if (stream != null) {
      try {
        final dir = await getTemporaryDirectory();
        final ext = (file.extension != null && file.extension!.isNotEmpty)
            ? file.extension!
            : 'm4a';
        final dest = File(
          p.join(
            dir.path,
            'minis_pick_${DateTime.now().microsecondsSinceEpoch}.$ext',
          ),
        );
        final sink = dest.openWrite();
        try {
          await for (final chunk in stream) {
            sink.add(chunk);
          }
        } finally {
          await sink.close();
        }
        if (!await dest.exists() || await dest.length() == 0) {
          return null;
        }
        return dest.absolute.path.replaceAll('\\', '/');
      } catch (e) {
        debugPrint('minis: audio stream copy failed: $e');
        return null;
      }
    }
    final bytes = file.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      try {
        final dir = await getTemporaryDirectory();
        final ext = (file.extension != null && file.extension!.isNotEmpty)
            ? file.extension!
            : 'm4a';
        final dest = File(
          p.join(
            dir.path,
            'minis_pick_${DateTime.now().microsecondsSinceEpoch}.$ext',
          ),
        );
        await dest.writeAsBytes(bytes, flush: true);
        return dest.absolute.path.replaceAll('\\', '/');
      } catch (e) {
        debugPrint('minis: audio bytes write failed: $e');
        return null;
      }
    }
    return null;
  }

  MinisHostMusicSelection? _currentHostSelection() {
    final seg = _musicSegment;
    if (seg == null) return null;
    return MinisHostMusicSelection(
      path: seg.path,
      startMs: seg.startMs,
      endMs: seg.endMs,
    );
  }

  Future<bool> _pickMusicFromHostIfAvailable() async {
    if (!MinisCaptureHost.isMusicPickerRegistered) return false;
    final selection = await MinisCaptureHost.pickMusic(
      currentSelection: _currentHostSelection(),
      sessionCapMs: _sessionCapMs,
    );
    if (!mounted) return true;
    if (selection == null) return true;
    if (selection.path.isEmpty) {
      _toast('Could not load selected music.');
      return true;
    }
    final segment = MinisMusicSegment(
      path: selection.path,
      startMs: math.max(0, selection.startMs),
      endMs: math.max(selection.startMs, selection.endMs),
    );
    setState(() => _musicSegment = segment);
    await _prepareGuideMusic();
    _toast('Music ready - long-press Sounds to clear');
    return true;
  }

  Future<void> _pickMusic() async {
    if (kIsWeb || _busy || _recording || _countingDown) return;
    try {
      final handledByHost = await _pickMusicFromHostIfAvailable();
      if (handledByHost) return;

      final existing = _musicSegment;
      if (minisAudioWaveformsTrimSupported() &&
          existing != null &&
          await File(existing.path).exists()) {
        if (!mounted) return;
        final segment = await showMinisMusicTimingSheet(
          context,
          audioPath: existing.path,
          sessionCapMs: _sessionCapMs,
          initialStartMs: existing.startMs,
        );
        if (!mounted) return;
        if (segment == null) return;
        setState(() => _musicSegment = segment);
        await _prepareGuideMusic();
        _toast('Music section updated - long-press Sounds to clear');
        return;
      }

      final r = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: kMinisAudioFileExtensions,
        dialogTitle: 'Choose audio',
        withReadStream: true,
      );
      final file = r?.files.single;
      if (!mounted) return;
      if (file == null) return;
      final path = await _materializePickedAudioForTrim(file);
      if (!mounted) return;
      if (path == null || path.isEmpty) {
        _toast('Could not read that audio file. Try another one.');
        return;
      }
      final extFromPicker = file.extension?.toLowerCase();
      final extFromPath = p.extension(path).toLowerCase().replaceFirst('.', '');
      final ext = (extFromPicker != null && extFromPicker.isNotEmpty)
          ? extFromPicker
          : extFromPath;
      if (!kMinisAudioFileExtensions.contains(ext)) {
        _toast('Please choose an audio file.');
        return;
      }
      if (!mounted) return;
      final segment = await showMinisMusicTimingSheet(
        context,
        audioPath: path,
        sessionCapMs: _sessionCapMs,
      );
      if (!mounted) return;
      if (segment == null) return;
      setState(() => _musicSegment = segment);
      await _prepareGuideMusic();
      _toast('Music ready - long-press Sounds to clear');
    } catch (e) {
      _toast('Music picker: $e');
    }
  }

  void _cycleSpeed() {
    if (_recording || _countingDown || _busy) return;
    setState(() {
      _speedIndex = (_speedIndex + 1) % _speedSteps.length;
    });
    _toast(
      'Record cap ${_effectiveMaxRecording.inSeconds}s at $_speedRailLabel '
      '(faster speed = shorter max clip).',
    );
  }

  void _cycleCountdownMode() {
    if (_recording || _countingDown || _busy) return;
    setState(() {
      _countdownMode = switch (_countdownMode) {
        MinisRecordCountdownMode.off => MinisRecordCountdownMode.three,
        MinisRecordCountdownMode.three => MinisRecordCountdownMode.ten,
        MinisRecordCountdownMode.ten => MinisRecordCountdownMode.off,
      };
    });
  }

  /// Copy a gallery-picked video into app documents so the path stays valid
  /// across async preview / append work (some platforms recycle temp paths).
  Future<String?> _materializePickedVideoForPreview(String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return null;
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(base.path, 'loopit_minis_captures'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = p.extension(sourcePath).toLowerCase();
      final safe = (ext.isNotEmpty && ext.length <= 8) ? ext : '.mp4';
      final dest = File(
        p.join(
          dir.path,
          'minis_gallery_in_${DateTime.now().microsecondsSinceEpoch}$safe',
        ),
      );
      await src.copy(dest.path);
      return dest.path.replaceAll('\\', '/');
    } catch (e) {
      debugPrint('minis: materialize gallery video failed: $e');
      return null;
    }
  }

  Future<Uint8List?> _thumbnailForVideoPath(
      String filePath, int durationMs) async {
    try {
      final tMs = durationMs > 120 ? durationMs - 100 : 0;
      return VideoThumbnail.thumbnailData(
        video: filePath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 480,
        quality: 88,
        timeMs: tMs,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _appendVideoSegment(String filePath, int durationMs) async {
    _logMulticlip(
      '_appendVideoSegment enter path=${p.basename(filePath)} durationMs=$durationMs',
    );
    final useMs = await minisFinalizeClipDurationMs(durationMs, filePath);
    _logMulticlip(
      '_appendVideoSegment finalizedMs=$useMs reportedMs=$durationMs '
      'path=${p.basename(filePath)}',
    );
    if (_clipsTotalDurationMs + useMs > _sessionCapMs) {
      _toast('That clip no longer fits the reel time.');
      return;
    }
    final thumb = await _thumbnailForVideoPath(filePath, useMs);
    if (!mounted) {
      _logMulticlip('_appendVideoSegment ABORT: not mounted after thumbnail');
      return;
    }
    setState(() {
      _videoClips.add(
        MinisRecordingClip(
          path: filePath,
          durationMs: useMs,
          thumbnailBytes: thumb,
        ),
      );
      _clipsTotalDurationMs += useMs;
      _lastCapturePath = null;
    });
    _logMulticlipState('clip appended (total clips=${_videoClips.length})');
    _toast('Clip ${_videoClips.length} added');
  }

  Future<void> _deleteLastVideoClip() async {
    if (_videoClips.isEmpty) return;
    final removed = _videoClips.removeLast();
    setState(() {
      _clipsTotalDurationMs =
          math.max(0, _clipsTotalDurationMs - removed.durationMs);
    });
    try {
      final f = File(removed.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _toast('Removed last clip');
  }

  /// Trim one segment (same stack as merged-reel trim). Closes any open sheet first.
  Future<void> _trimClipAtIndex(int index) async {
    if (!minisReelClipTrimmerPlatformSupported()) {
      _toast('Trim works on Android and iOS.');
      return;
    }
    if (index < 0 || index >= _videoClips.length) return;
    if (_busy || _recording || _countingDown) return;
    final clip = _videoClips[index];
    final file = File(clip.path);
    if (!await file.exists()) {
      _toast('Clip file missing.');
      return;
    }
    setState(() => _busy = true);
    MinisReelTrimResult? result;
    try {
      result = await MinisReelClipTrimmerPage.open(context, file);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || result == null || result.path.isEmpty) return;
    try {
      // Trimmer span + file finalize (same ~1s probe issue as append).
      final newMs =
          await minisFinalizeClipDurationMs(result.durationMs, result.path);
      final delta = newMs - clip.durationMs;
      if (_clipsTotalDurationMs + delta > _sessionCapMs) {
        _toast('Trimmed clip no longer fits the reel time cap.');
        try {
          await File(result.path).delete();
        } catch (_) {}
        return;
      }
      final thumb = await _thumbnailForVideoPath(result.path, newMs);
      if (!mounted) return;
      final oldPath = clip.path;
      final outPath = result.path;
      setState(() {
        _clipsTotalDurationMs += delta;
        _videoClips[index] = MinisRecordingClip(
          path: outPath,
          durationMs: newMs,
          thumbnailBytes: thumb,
        );
      });
      if (oldPath != outPath) {
        try {
          await File(oldPath).delete();
        } catch (_) {}
      }
      _toast('Clip ${index + 1} trimmed');
    } catch (e, st) {
      logVideoTrimDiagnostic(
        e,
        stackTrace: st,
        context: 'MinisCapture._trimClipAtIndex',
        extra: {
          'clipIndex': index,
          'sourceFile': p.basename(clip.path),
          'resultPath': p.basename(result.path),
        },
      );
      _toast(messageForVideoTrimFailure(e));
      try {
        await File(result.path).delete();
      } catch (_) {}
    }
  }

  /// [previewDurationMs]: when the clip was just confirmed from [MinisVideoPreviewPage],
  /// pass the player-reported duration (avoids repeated ~1s file probes on MP4s).
  Future<void> _appendGalleryVideoAfterPreview(
    String confirmedPath, {
    int? previewDurationMs,
  }) async {
    _logMulticlip(
      '_appendGalleryVideoAfterPreview enter confirmed=${p.basename(confirmedPath)} '
      'mergeSupported=${minisMulticlipMergeSupported()} '
      'previewDurationMs=$previewDurationMs',
    );
    _logMulticlipState('state before probe');
    if (!minisMulticlipMergeSupported()) {
      _logMulticlip(
        'branch: multiclip merge NOT supported — storing single-clip handoff only',
      );
      setState(() {
        _lastCapturePath = confirmedPath;
        _lastCaptureIsVideo = true;
      });
      _toast('Video ready (single clip on this platform).');
      return;
    }
    try {
      final int clipMs;
      if (previewDurationMs != null && previewDurationMs > 0) {
        clipMs = previewDurationMs;
        _logMulticlip(
          'duration from preview (authoritative): clipMs=$clipMs path=${p.basename(confirmedPath)}',
        );
      } else {
        clipMs = await minisResolveVideoDurationMsBestEffort(confirmedPath);
        _logMulticlip(
          'duration from probe (no preview ms): clipMs=$clipMs',
        );
      }
      final used = _clipsTotalDurationMs;
      final cap = _sessionCapMs;
      final sum = used + clipMs;
      _logMulticlip(
        'duration (post-preview flow): newClipMs=$clipMs usedMs=$used '
        'capMs=$cap sumIfAdded=$sum',
      );
      if (clipMs <= 0) {
        _logMulticlip('REJECT: clipMs<=0 (metadata/probe failed)');
        _toast('Could not read this video\'s length. Try another file.');
        return;
      }
      if (sum > cap) {
        _logMulticlip(
          'REJECT: over cap after preview (sum=$sum cap=$cap) — should be rare',
        );
        _toast('That clip no longer fits the reel time. Try again.');
        return;
      }
      _logMulticlip('calling _appendVideoSegment');
      await _appendVideoSegment(confirmedPath, clipMs);
      _logMulticlip('_appendGalleryVideoAfterPreview OK');
    } catch (e, st) {
      _logMulticlip('REJECT: exception: $e\n$st');
      _toast('Could not read video: $e');
    }
  }

  void _showMultiClipReviewSheet() {
    if (_videoClips.isEmpty) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final listHeight = math.min(
              420.0,
              88.0 * _videoClips.length + 16,
            );
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Multi-clip',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_videoClips.length} segment${_videoClips.length == 1 ? '' : 's'}. '
                      'Drag the handle to reorder merge order. Trim edits one file. '
                      'Use gallery (images) below to add from the library; undo removes the last clip.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: listHeight,
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          canvasColor: const Color(0xFF1C1C1E),
                        ),
                        child: ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: _videoClips.length,
                          onReorder: (oldIndex, newIndex) {
                            setState(() {
                              var n = newIndex;
                              if (n > oldIndex) n -= 1;
                              final c = _videoClips.removeAt(oldIndex);
                              _videoClips.insert(n, c);
                            });
                            setModalState(() {});
                          },
                          itemBuilder: (context, index) {
                            final clip = _videoClips[index];
                            final bytes = clip.thumbnailBytes;
                            final sec =
                                (clip.durationMs / 1000).ceil().clamp(1, 999);
                            final trimSupported =
                                minisReelClipTrimmerPlatformSupported();
                            return Padding(
                              key: ValueKey<String>(clip.path),
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Material(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  leading: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: SizedBox(
                                      width: 56,
                                      height: 56,
                                      child: bytes != null
                                          ? Image.memory(
                                              bytes,
                                              fit: BoxFit.cover,
                                            )
                                          : ColoredBox(
                                              color: Colors.white.withValues(
                                                alpha: 0.12,
                                              ),
                                              child: const Center(
                                                child: PhosphorIcon(
                                                  PhosphorIconsRegular
                                                      .videoCamera,
                                                  color: Colors.white54,
                                                  size: 24,
                                                ),
                                              ),
                                            ),
                                    ),
                                  ),
                                  title: Text(
                                    'Clip ${index + 1} · ${sec}s',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  subtitle: Text(
                                    trimSupported
                                        ? 'Merge order: ${index + 1} of ${_videoClips.length}'
                                        : 'Reorder for merge · trim on device',
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.55),
                                      fontSize: 12,
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        onPressed: (_busy ||
                                                _recording ||
                                                _countingDown ||
                                                !trimSupported)
                                            ? null
                                            : () async {
                                                Navigator.of(sheetCtx).pop();
                                                await _trimClipAtIndex(index);
                                                if (mounted &&
                                                    _videoClips.isNotEmpty) {
                                                  _showMultiClipReviewSheet();
                                                }
                                              },
                                        child: Text(
                                          'Trim',
                                          style: TextStyle(
                                            color: trimSupported
                                                ? const Color(0xFF7DD3FC)
                                                : Colors.white38,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: const Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Icon(
                                            Icons.drag_handle,
                                            color: Colors.white54,
                                            size: 28,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openGallery() async {
    _logMulticlipState('_openGallery enter');
    if (_busy || _recording || _countingDown) {
      _logMulticlip(
        '_openGallery SKIP: busy=$_busy recording=$_recording countingDown=$_countingDown',
      );
      return;
    }
    if (kIsWeb) {
      _toast('Gallery is for Android / iOS builds.');
      return;
    }
    try {
      final picker = ImagePicker();
      XFile? x;
      try {
        x = await picker.pickMedia(imageQuality: 92);
      } catch (_) {
        x = await picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 92,
        );
      }
      if (x == null) {
        _logMulticlip('picker returned null (user cancelled)');
        return;
      }
      if (!mounted) {
        _logMulticlip('ABORT after pick: not mounted');
        return;
      }
      final path = x.path;
      final isVideo = _pickedXFileIsVideo(x);
      _logMulticlip(
        'picked path=${p.basename(path)} isVideo=$isVideo mime=${x.mimeType}',
      );

      if (!isVideo) {
        if (widget.videoOnly) {
          _toast('Minis is video only — choose a video from your library.');
          return;
        }
        final edited = await openMinisProImageEditor(context, path);
        if (!mounted) return;
        if (edited != null && edited.isNotEmpty) {
          debugPrint('MINIS_FLOW capture: gallery image edited path=$edited');
          _deliverConfirmedCapture(edited);
        } else {
          _toast('Image edit cancelled');
        }
        return;
      }

      final materialized = await _materializePickedVideoForPreview(path);
      if (!mounted) {
        _logMulticlip('ABORT after materialize: not mounted');
        return;
      }
      if (materialized == null) {
        _logMulticlip('REJECT: materialize copy failed (null path)');
        _toast('Could not read the selected video file.');
        return;
      }
      _logMulticlip('materialized to=${p.basename(materialized)}');

      // Single-clip platforms: preview then hand off (no merge stack).
      if (!minisMulticlipMergeSupported()) {
        final preview = await openMinisVideoPreview(context, materialized);
        if (!mounted) {
          try {
            await File(materialized).delete();
          } catch (_) {}
          return;
        }
        if (preview != null && preview.path.isNotEmpty) {
          await _appendGalleryVideoAfterPreview(
            preview.path,
            previewDurationMs: preview.durationMs,
          );
        } else {
          try {
            await File(materialized).delete();
          } catch (_) {}
          _toast('Video preview dismissed');
        }
        return;
      }

      final remainingMs =
          _sessionCapMs - _clipsTotalDurationMs - _liveClipElapsedMs;
      final clipMsProbe = await minisResolveVideoDurationMsBestEffort(materialized);
      _logMulticlip(
        'gallery probe (pre-preview): clipMs=$clipMsProbe remainingBudgetMs=$remainingMs '
        'sessionCapMs=$_sessionCapMs usedMs=$_clipsTotalDurationMs',
      );

      if (clipMsProbe <= 0) {
        _toast('Could not read this video\'s length. Try another file.');
        try {
          await File(materialized).delete();
        } catch (_) {}
        return;
      }

      if (remainingMs < 500) {
        _toast('No time left on this reel.');
        try {
          await File(materialized).delete();
        } catch (_) {}
        return;
      }

      // Longer than what fits: trim first (so multi-clip UX is not "dead" until user guesses length).
      if (clipMsProbe > remainingMs) {
        if (!minisReelClipTrimmerPlatformSupported()) {
          _toast(
            'This video is longer than the ${(remainingMs / 1000).ceil()}s left. '
            'Pick a shorter clip or trim it in your gallery app first.',
          );
          try {
            await File(materialized).delete();
          } catch (_) {}
          return;
        }
        final remSec = (remainingMs / 1000).ceil();
        _toast(
          'Trim which ${remSec}s or less to add (${remSec}s left on this reel).',
        );
        if (!mounted) return;
        setState(() => _busy = true);
        MinisReelTrimResult? trimOut;
        try {
          trimOut = await MinisReelClipTrimmerPage.open(
            context,
            File(materialized),
            maxOutputDuration: Duration(milliseconds: remainingMs),
          );
        } finally {
          if (mounted) setState(() => _busy = false);
        }
        if (!mounted) return;
        if (trimOut == null || trimOut.path.isEmpty) {
          _logMulticlip('mandatory trim cancelled or empty');
          try {
            await File(materialized).delete();
          } catch (_) {}
          return;
        }
        final outMs = trimOut.durationMs;
        if (outMs <= 0 || _clipsTotalDurationMs + outMs > _sessionCapMs) {
          _toast('Trimmed segment does not fit the reel.');
          try {
            await File(trimOut.path).delete();
          } catch (_) {}
          try {
            await File(materialized).delete();
          } catch (_) {}
          return;
        }
        await _appendVideoSegment(trimOut.path, outMs);
        if (trimOut.path != materialized) {
          try {
            await File(materialized).delete();
          } catch (_) {}
        }
        return;
      }

      // Fits within remaining budget — optional preview, then append.
      if (!mounted) return;
      final preview = await openMinisVideoPreview(context, materialized);
      if (!mounted) {
        _logMulticlip(
          'ABORT after preview: not mounted — skipping append (lifecycle): '
          'dispose/route pop; temp copy may be deleted',
        );
        try {
          await File(materialized).delete();
        } catch (_) {}
        return;
      }
      if (preview != null && preview.path.isNotEmpty) {
        _logMulticlip(
          'preview confirmed path=${p.basename(preview.path)} '
          'durationMs=${preview.durationMs} '
          '(may differ if user trimmed in preview)',
        );
        if (preview.path != materialized) {
          _logMulticlip('note: confirmed != materialized (trim export new file)');
        }
        await _appendGalleryVideoAfterPreview(
          preview.path,
          previewDurationMs: preview.durationMs,
        );
      } else {
        _logMulticlip('preview dismissed or empty result (preview=$preview)');
        try {
          await File(materialized).delete();
        } catch (_) {}
        _toast('Video preview dismissed');
      }
    } catch (e, st) {
      _logMulticlip('Gallery error: $e\n$st');
      _toast('Gallery: $e');
    }
  }

  Future<void> _confirmClip() async {
    debugPrint(
      'MINIS_FLOW capture: confirm tapped clips=${_videoClips.length} '
      'lastPath=${_lastCapturePath ?? ''} isVideo=$_lastCaptureIsVideo',
    );
    if (_videoClips.isNotEmpty) {
      if (_busy || _recording || _countingDown) return;
      if (!minisMulticlipMergeSupported()) {
        _toast('Merging clips requires Android, iOS, or macOS.');
        return;
      }
      setState(() => _busy = true);
      try {
        final paths = _videoClips.map((c) => c.path).toList();
        final merged = await mergeMinisVideoClipsWithDialog(
          context: context,
          clipPaths: paths,
          playbackSpeed: _speedSteps[_speedIndex],
          enableAudio: _micEnabled,
          backgroundMusic: _musicSegment,
        );
        if (!mounted) return;
        if (merged == null || merged.isEmpty) {
          _toast('Merge cancelled or failed.');
          return;
        }
        if (mounted) setState(() => _busy = false);
        final ready = await waitUntilMinisVideoFileReady(merged);
        if (!mounted) return;
        if (!ready) {
          _toast('Merged video not found or still writing. Try again.');
          try {
            await File(merged).delete();
          } catch (_) {}
          return;
        }
        if (!mounted) return;
        final mergedPreview = await MinisVideoPreviewPage.open(
          context,
          merged,
          title: 'Merged reel',
          confirmLabel: 'Use reel',
          allowReelTrim: minisReelClipTrimmerPlatformSupported(),
        );
        if (!mounted) return;
        if (mergedPreview == null || mergedPreview.path.isEmpty) {
          try {
            await File(merged).delete();
          } catch (_) {}
          _toast('Reel preview dismissed');
          return;
        }
        for (final c in _videoClips) {
          try {
            final f = File(c.path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        if (!mounted) return;
        if (mergedPreview.path != merged) {
          try {
            await File(merged).delete();
          } catch (_) {}
        }
        setState(() {
          _videoClips.clear();
          _clipsTotalDurationMs = 0;
        });
        if (!mounted) return;
        _deliverConfirmedCapture(mergedPreview.path);
      } catch (e) {
        if (mounted) _toast('Merge failed: $e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    final path = _lastCapturePath;
    if (path == null || path.isEmpty) return;

    if (_lastCaptureIsVideo) {
      final seg = _musicSegment;
      final hasMusic = seg != null && File(seg.path).existsSync();
      if (hasMusic) {
        if (!minisMulticlipMergeSupported()) {
          _toast('Mixing music requires Android, iOS, or macOS.');
        } else {
          setState(() => _busy = true);
          try {
            final merged = await mergeMinisVideoClipsWithDialog(
              context: context,
              clipPaths: [path],
              playbackSpeed: _speedSteps[_speedIndex],
              enableAudio: _micEnabled,
              backgroundMusic: seg,
            );
            if (!mounted) return;
            if (merged == null || merged.isEmpty) {
              _toast('Mix cancelled or failed.');
              return;
            }
            final ready = await waitUntilMinisVideoFileReady(merged);
            if (!mounted) return;
            if (!ready) {
              _toast('Mixed video not ready.');
              try {
                await File(merged).delete();
              } catch (_) {}
              return;
            }
            _deliverConfirmedCapture(merged);
          } catch (e) {
            if (mounted) _toast('Mix failed: $e');
          } finally {
            if (mounted) setState(() => _busy = false);
          }
          return;
        }
      }
    }

    _deliverConfirmedCapture(path);
  }

  void _deliverConfirmedCapture(String path) {
    debugPrint('MINIS_FLOW capture: deliver confirmed path=$path');
    MinisCaptureHost.completeCaptureResult(path);
    debugPrint('MINIS_FLOW capture: host result completed');
    final cb = widget.onClipConfirmed;
    if (cb != null) {
      debugPrint('MINIS_FLOW capture: using host callback');
      cb(path);
      return;
    }
    final nav = Navigator.maybeOf(context);
    if (nav != null && nav.canPop()) {
      debugPrint('MINIS_FLOW capture: local navigator pop with path');
      nav.pop<String>(path);
      return;
    }
    final rootNav = Navigator.maybeOf(context, rootNavigator: true);
    if (rootNav != null && rootNav.canPop()) {
      debugPrint('MINIS_FLOW capture: root navigator pop with path');
      rootNav.pop<String>(path);
      return;
    }
    debugPrint('MINIS_FLOW capture: fallback persist path');
    unawaited(_persistCaptureFallback(path));
  }

  Future<void> _persistCaptureFallback(String sourcePath) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final sub = Directory(p.join(dir.path, 'minis_captures'));
      if (!await sub.exists()) {
        await sub.create(recursive: true);
      }
      final ext = p.extension(sourcePath);
      final name =
          'minis_${DateTime.now().millisecondsSinceEpoch}${ext.isEmpty ? '' : ext}';
      final dest = File(p.join(sub.path, name));
      await File(sourcePath).copy(dest.path);
      if (mounted) {
        _toast('Saved to ${dest.path}');
      }
    } catch (e) {
      if (mounted) _toast('Save failed: $e');
    }
  }

  Future<void> _toggleMic() async {
    if (_recording || _busy || _countingDown) return;
    final eng = _engine;
    if (eng == null) return;
    final next = !_micEnabled;
    setState(() => _busy = true);
    try {
      await eng.setRecordWithAudio(next);
      if (mounted) setState(() => _micEnabled = next);
    } catch (e) {
      _toast('Mic setting failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleTorch() async {
    if (_recording || _busy || _countingDown) return;
    final eng = _engine;
    if (eng == null) return;
    final wantOn = !eng.isTorchOn;
    setState(() => _busy = true);
    try {
      await eng.setTorchEnabled(wantOn);
      if (mounted) setState(() {});
    } catch (e) {
      _toast('Flash not available on this lens.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startRecordingInternal() async {
    final eng = _engine;
    if (eng == null || !eng.isInitialized || _recording) return;
    if (_clipsTotalDurationMs >= _sessionCapMs) {
      _toast('Reel time limit reached. Tap check to merge or remove a clip.');
      return;
    }
    final budgetMs = _sessionCapMs - _clipsTotalDurationMs;
    final cap = Duration(milliseconds: math.max(1, budgetMs));
    try {
      await eng.startRecording();
      if (!mounted) return;
      _activeClipStartedAt = DateTime.now();
      _clipBudgetMsAtRecordStart = budgetMs;
      setState(() => _recording = true);
      unawaited(_primeZoomForRecording());
      unawaited(_startGuideMusicForRecording());
      unawaited(_ensureGuideMusicPlayingAfterRecordStart());
      _clipElapsedTicker?.cancel();
      _clipElapsedTicker =
          Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted && _recording) setState(() {});
      });
      _maxRecordTimer?.cancel();
      _maxRecordTimer = Timer(cap, () {
        if (mounted && _recording) {
          unawaited(
            _stopRecordingInternal(
              userMessage:
                  'Max reel time reached for this segment ($_speedRailLabel)',
            ),
          );
        }
      });
    } catch (e) {
      _activeClipStartedAt = null;
      _toast('Recording error: $e');
    }
  }

  Future<void> _stopRecordingInternal({String? userMessage}) async {
    final eng = _engine;
    if (eng == null || !_recording) return;
    await _pauseGuideMusic();
    _maxRecordTimer?.cancel();
    _maxRecordTimer = null;
    _clipElapsedTicker?.cancel();
    _clipElapsedTicker = null;
    final started = _activeClipStartedAt;
    _activeClipStartedAt = null;
    var rawElapsed =
        started != null ? DateTime.now().difference(started).inMilliseconds : 0;
    rawElapsed = math.min(rawElapsed, _clipBudgetMsAtRecordStart);
    try {
      final path = await eng.stopRecording();
      if (!mounted) return;
      setState(() => _recording = false);
      _zoomGesturePointer = null;
      unawaited(_resetZoomAfterRecording());
      if (path != null && path.isNotEmpty) {
        final d = math.max(1, rawElapsed);
        await _appendVideoSegment(path, d);
      } else {
        _toast('No video file from camera.');
      }
      if (userMessage != null && mounted) {
        _toast(userMessage);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _recording = false);
        _zoomGesturePointer = null;
      }
      unawaited(_resetZoomAfterRecording());
      _toast('Stop failed: $e');
    }
  }

  Future<void> _primeZoomForRecording() async {
    final eng = _engine;
    if (eng == null || !mounted) return;
    try {
      var lo = await eng.getMinZoomLevel();
      var hi = await eng.getMaxZoomLevel();
      if (!mounted || !_recording) return;
      if (lo > hi) {
        final t = lo;
        lo = hi;
        hi = t;
      }
      if (hi - lo < 1e-6) {
        setState(() {
          _zoomMin = lo;
          _zoomMax = hi;
          _zoomLevel = lo;
        });
        return;
      }
      await eng.setZoomLevel(lo);
      if (!mounted || !_recording) return;
      setState(() {
        _zoomMin = lo;
        _zoomMax = hi;
        _zoomLevel = lo;
      });
    } catch (_) {}
  }

  Future<void> _resetZoomAfterRecording() async {
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    try {
      await eng.setZoomLevel(_zoomMin);
    } catch (_) {}
  }

  void _onPreviewZoomPointerDown(PointerDownEvent e) {
    if (!_recording) return;
    _zoomGesturePointer = e.pointer;
    _zoomPanStartY = e.localPosition.dy;
    _zoomPanStartLevel = _zoomLevel;
  }

  void _onPreviewZoomPointerMove(PointerMoveEvent e) {
    if (!_recording || e.pointer != _zoomGesturePointer) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    final span = _zoomMax - _zoomMin;
    if (span <= 1e-6) return;
    final h = MediaQuery.sizeOf(context).height;
    if (h <= 0) return;
    // Finger up (smaller dy) → zoom in; finger down → zoom out.
    final deltaY = e.localPosition.dy - _zoomPanStartY;
    const sensitivity = 1.85;
    var next = _zoomPanStartLevel - (deltaY / h) * span * sensitivity;
    next = next.clamp(_zoomMin, _zoomMax);
    if ((next - _zoomLevel).abs() < 0.002) return;
    _zoomLevel = next;
    unawaited(eng.setZoomLevel(next));
  }

  void _onPreviewZoomPointerUpOrCancel(PointerEvent e) {
    if (e.pointer == _zoomGesturePointer) {
      _zoomGesturePointer = null;
    }
  }

  void _onShutterPointerDown(PointerDownEvent event) {
    if (_busy || _countingDown) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized || _recording) return;
    if (_clipsTotalDurationMs >= _sessionCapMs) {
      _toast('Reel time limit reached.');
      return;
    }
    _holdStartTimer?.cancel();
    _shutterFingerDown = true;
    _holdVideoArmed = false;
    _holdStartTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted || !_shutterFingerDown) return;
      _holdVideoArmed = true;
      unawaited(_startRecordingInternal());
    });
  }

  void _onShutterPointerUpOrCancel() {
    _holdStartTimer?.cancel();
    _holdStartTimer = null;
    final wasHold = _holdVideoArmed;
    _shutterFingerDown = false;
    _holdVideoArmed = false;
    if (wasHold) {
      if (_recording) {
        unawaited(_stopRecordingInternal());
      }
      return;
    }
    if (widget.videoOnly) {
      _toast('Minis is video only — hold to record.');
      return;
    }
    unawaited(_shutterShortTapPhoto());
  }

  Future<void> _shutterShortTapPhoto() async {
    if (_busy || _recording || _countingDown) return;
    if (_videoClips.isNotEmpty) {
      _toast('Finish or clear your reel before taking a photo.');
      return;
    }
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;

    final sec = switch (_countdownMode) {
      MinisRecordCountdownMode.off => 0,
      MinisRecordCountdownMode.three => 3,
      MinisRecordCountdownMode.ten => 10,
    };

    if (sec > 0) {
      await _pauseGuideMusic();
      setState(() {
        _countingDown = true;
        _countdownTick = sec;
      });
      for (var i = sec; i > 0; i--) {
        if (!mounted) return;
        setState(() => _countdownTick = i);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!mounted) return;
      setState(() {
        _countingDown = false;
        _countdownTick = null;
      });
    }

    await _takePhotoFromCamera();
  }

  Future<void> _takePhotoFromCamera() async {
    final eng = _engine;
    if (eng == null || !eng.isInitialized || _recording) return;
    setState(() => _busy = true);
    try {
      final path = await eng.takePicture();
      if (!mounted) return;
      if (path == null || path.isEmpty) {
        _toast('Could not capture photo');
        return;
      }
      final edited = await openMinisProImageEditor(context, path);
      if (!mounted) return;
      if (edited != null && edited.isNotEmpty) {
        debugPrint('MINIS_FLOW capture: camera image edited path=$edited');
        _deliverConfirmedCapture(edited);
      } else {
        _toast('Image edit cancelled');
      }
    } catch (e) {
      _toast('Photo error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cancelCountdown() {
    if (!_countingDown) return;
    setState(() {
      _countingDown = false;
      _countdownTick = null;
    });
  }

  Future<void> _flip() async {
    if (_recording || _countingDown) return;
    final eng = _engine;
    if (eng == null) return;
    setState(() => _busy = true);
    try {
      await eng.switchCamera();
      if (mounted) setState(() {});
    } catch (e) {
      _toast('Flip failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _railAction({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Color? iconColor,
    VoidCallback? onLongPress,
  }) {
    final disabled = onTap == null;
    return SizedBox(
      width: _kRailColumnWidth,
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  height: _kRailIconSlotHeight,
                  child: Center(
                    child: PhosphorIcon(
                      icon,
                      color: iconColor ?? Colors.white,
                      size: _kRailIconSize,
                    ),
                  ),
                ),
                SizedBox(
                  height: _kRailLabelSlotHeight,
                  width: _kRailColumnWidth,
                  child: Center(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _railChevronToggle() {
    final disabled = _busy || _recording || _countingDown;
    return SizedBox(
      width: _kRailColumnWidth,
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: InkWell(
          onTap: disabled
              ? null
              : () => setState(() => _railExpanded = !_railExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  height: _kRailIconSlotHeight,
                  child: Center(
                    child: PhosphorIcon(
                      _railExpanded
                          ? PhosphorIconsRegular.caretUp
                          : PhosphorIconsRegular.caretDown,
                      color: Colors.white,
                      size: _kRailChevronSize,
                    ),
                  ),
                ),
                const SizedBox(
                  height: _kRailLabelSlotHeight,
                  width: _kRailColumnWidth,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _roundSecondaryButton({
    required IconData icon,
    required VoidCallback? onPressed,
    bool filled = true,
  }) {
    return Material(
      color: filled
          ? Colors.white.withValues(alpha: 0.22)
          : Colors.white.withValues(alpha: 0.08),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: _kCornerBtnSize,
          height: _kCornerBtnSize,
          child: PhosphorIcon(
            icon,
            color: onPressed == null
                ? Colors.white.withValues(alpha: 0.35)
                : Colors.white,
            size: _kCornerIconSize,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_webUnsupported) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('Minis')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Independent Minis capture uses the camera plugin on '
              'Android and iOS only. Run the example on a device or emulator.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_permissionDenied) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('Minis')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Camera and microphone permission are required to record.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    await openAppSettings();
                  },
                  child: const Text('Open settings'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('Minis')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final eng = _engine;
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          if (eng != null && !_busy)
            Positioned.fill(child: eng.buildPreview(context)),
          if (_busy)
            const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_recording && eng != null && !_busy)
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onPreviewZoomPointerDown,
                onPointerMove: _onPreviewZoomPointerMove,
                onPointerUp: _onPreviewZoomPointerUpOrCancel,
                onPointerCancel: _onPreviewZoomPointerUpOrCancel,
                child: const SizedBox.expand(),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () {
                        final nav = Navigator.maybeOf(context);
                        if (nav != null && nav.canPop()) {
                          nav.pop();
                        }
                      },
                      icon: const PhosphorIcon(
                        PhosphorIconsRegular.caretLeft,
                        color: Colors.white,
                        size: _kAppBarIconSize,
                      ),
                    ),
                    const Spacer(),
                    if (_recording)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PhosphorIcon(
                                PhosphorIconsRegular.videoCamera,
                                color: Colors.white,
                                size: _kStatusPillIconSize,
                              ),
                              SizedBox(width: 6),
                              Text(
                                'REC',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                  height: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: topPad + 52,
            right: 4,
            bottom: bottomPad + 132,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _railAction(
                    icon: PhosphorIconsRegular.cameraRotate,
                    label: 'Flip',
                    onTap:
                        (_busy || _recording || _countingDown) ? null : _flip,
                  ),
                  if (_railExpanded) ...[
                    _railAction(
                      icon: PhosphorIconsRegular.musicNotes,
                      label: _musicSegment == null ? 'Sounds' : 'Music',
                      iconColor: _musicSegment != null
                          ? const Color(0xFF7DD3FC)
                          : null,
                      onTap: (_busy || _recording || _countingDown)
                          ? null
                          : _pickMusic,
                      onLongPress: (_busy ||
                              _recording ||
                              _countingDown ||
                              _musicSegment == null)
                          ? null
                          : () => unawaited(_clearMusic()),
                    ),
                    _railAction(
                      icon: PhosphorIconsRegular.gauge,
                      label: _speedRailLabel,
                      onTap: (_busy || _recording || _countingDown)
                          ? null
                          : _cycleSpeed,
                    ),
                    if (!widget.videoOnly)
                      _railAction(
                        icon: PhosphorIconsRegular.timer,
                        label: _timerRailLabel,
                        onTap: (_busy || _recording || _countingDown)
                            ? null
                            : _cycleCountdownMode,
                      ),
                  ],
                  _railAction(
                    icon: eng?.isTorchOn == true
                        ? PhosphorIconsRegular.lightning
                        : PhosphorIconsRegular.lightningSlash,
                    label: 'Flash',
                    onTap: (_busy || _recording || _countingDown)
                        ? null
                        : _toggleTorch,
                  ),
                  _railAction(
                    icon: _micEnabled
                        ? PhosphorIconsRegular.microphone
                        : PhosphorIconsRegular.microphoneSlash,
                    label: 'Mic',
                    onTap: (_busy || _recording || _countingDown)
                        ? null
                        : _toggleMic,
                  ),
                  _railChevronToggle(),
                ],
              ),
            ),
          ),
          if (_countingDown && _countdownTick != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _cancelCountdown,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_countdownTick',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 96,
                            fontWeight: FontWeight.w200,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Tap to cancel',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      flex: 1,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: _videoClips.isNotEmpty
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _roundSecondaryButton(
                                      icon: PhosphorIconsRegular.images,
                                      onPressed: (_busy ||
                                              _recording ||
                                              _countingDown)
                                          ? null
                                          : () => unawaited(_openGallery()),
                                    ),
                                    const SizedBox(width: 8),
                                    _roundSecondaryButton(
                                      icon: PhosphorIconsRegular.arrowUUpLeft,
                                      onPressed: (_busy ||
                                              _recording ||
                                              _countingDown)
                                          ? null
                                          : () => unawaited(
                                                _deleteLastVideoClip(),
                                              ),
                                    ),
                                  ],
                                )
                              : _roundSecondaryButton(
                                  icon: PhosphorIconsRegular.images,
                                  onPressed: (_busy ||
                                          _recording ||
                                          _countingDown)
                                      ? null
                                      : () => unawaited(_openGallery()),
                                ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _videoClips.isEmpty
                                ? '${_effectiveMaxRecording.inSeconds}s max'
                                : '${(_remainingSessionMs / 1000).ceil()}s left - '
                                    '${_videoClips.length} clip${_videoClips.length == 1 ? '' : 's'}',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.92),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.videoOnly
                                ? (_videoClips.isNotEmpty
                                    ? 'Hold to record · gallery (left) for videos'
                                    : 'Hold to record video')
                                : (_videoClips.isNotEmpty
                                    ? 'Hold to add another · Tap for photo · gallery (left)'
                                    : 'Hold for video · Tap for photo'),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 11,
                            ),
                          ),
                          if (_videoClips.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            // [Row] + [Flexible] needs a bounded width: stretch the column and
                            // use [mainAxisSize.max] so the label ellipsizes instead of
                            // overflowing the bottom bar on narrow screens.
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: (_busy || _recording || _countingDown)
                                    ? null
                                    : _showMultiClipReviewSheet,
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.max,
                                    children: [
                                      PhosphorIcon(
                                        PhosphorIconsRegular.stack,
                                        size: 17,
                                        color: Colors.white
                                            .withValues(alpha: 0.95),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          'Multi-clip - ${_videoClips.length}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Center(
                            child: SizedBox(
                              width: _kShutterOuter,
                              height: _kShutterOuter,
                              child: Stack(
                                alignment: Alignment.center,
                                clipBehavior: Clip.none,
                                children: [
                                  CustomPaint(
                                    size: const Size(
                                      _kShutterOuter,
                                      _kShutterOuter,
                                    ),
                                    painter: MinisRecordingRingPainter(
                                      progress: _recordRingProgress,
                                      trackColor: _recording
                                          ? Colors.white.withValues(alpha: 0.28)
                                          : Colors.white,
                                      progressColor: Colors.redAccent,
                                      strokeWidth: _kRecordingRingStroke,
                                    ),
                                  ),
                                  Listener(
                                    onPointerDown: _onShutterPointerDown,
                                    onPointerUp: (_) =>
                                        _onShutterPointerUpOrCancel(),
                                    onPointerCancel: (_) =>
                                        _onShutterPointerUpOrCancel(),
                                    child: Container(
                                      width: _kShutterInner,
                                      height: _kShutterInner,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _recording
                                            ? Colors.redAccent
                                                .withValues(alpha: 0.22)
                                            : Colors.white.withValues(alpha: 0.08),
                                      ),
                                      alignment: Alignment.center,
                                      child: _recording
                                          ? const PhosphorIcon(
                                              PhosphorIconsRegular.stop,
                                              color: Colors.redAccent,
                                              size: _kShutterStopIconSize,
                                            )
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 1,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (_videoClips.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  'Merge reel',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    fontSize: 11,
                                  ),
                                ),
                              )
                            else if (_lastCapturePath != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  _lastCaptureIsVideo ? 'Video' : 'Photo',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            _roundSecondaryButton(
                              icon: PhosphorIconsRegular.check,
                              filled: _canConfirmClip,
                              onPressed: _canConfirmClip
                                  ? () => unawaited(_confirmClip())
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
