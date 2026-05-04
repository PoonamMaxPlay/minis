import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'package:loopit_minis/src/independent/camera_plugin_minis_engine.dart';
import 'package:loopit_minis/src/independent/minis_camera_engine_factory.dart';
import 'package:loopit_minis/src/independent/minis_camera_performance.dart';
import 'package:loopit_minis/src/independent/minis_gallery_preview.dart';
import 'package:loopit_minis/src/independent/minis_video_duration.dart';
import 'package:loopit_minis/src/independent/minis_multiclip_merge.dart';
import 'package:loopit_minis/src/independent/minis_music_segment.dart';
import 'package:loopit_minis/src/independent/minis_music_trim_sheet.dart';
import 'package:loopit_minis/src/independent/minis_recording_clip.dart';
import 'package:loopit_minis/src/independent/minis_recording_ring_painter.dart';
import 'package:loopit_minis/src/independent/minis_reel_clip_trimmer_page.dart';
import 'package:loopit_minis/src/independent/minis_video_preview_page.dart';
import 'package:loopit_minis/src/minis_handoff.dart';
import 'package:loopit_minis/src/native_video_trim_user_message.dart'
    show logVideoTrimDiagnostic, messageForVideoTrimFailure;
import 'package:loopit_minis/src/session_and_toast.dart';
import 'package:loopit_minis/src/minis_capture_host.dart';
import 'package:loopit_minis/src/minis_capture_ports.dart';
import 'package:loopit_minis/src/minis_user_message.dart';
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
/// **videoOnly** is set (host “Minis / reel” flows — video only). **Swipe
/// up/down on the preview** to zoom in/out anytime the camera is idle or while
/// recording (device support via [MinisCameraEnginePort] zoom). Each
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
    this.maxRecordingDuration = const Duration(seconds: 180),
    this.onClipConfirmed,
    this.initialMusicPath,
    this.initialMusicStartMs = 0,
    this.initialMusicEndMs,
    this.videoOnly = false,
    this.cameraPerformanceMode = MinisCameraPerformanceMode.auto,
    this.useNativeAndroidCamera = false,
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

  /// Selects preview/capture resolution for the default [CameraPluginMinisEngine].
  /// Ignored when [engine] is provided. Defaults to device heuristics ([auto]).
  final MinisCameraPerformanceMode cameraPerformanceMode;

  /// Android: use CameraX embedded in a Platform View instead of the Flutter
  /// `camera` plugin ([NativeAndroidMinisCameraEngine]). Default off; enable with
  /// host flag / `--dart-define=USE_NATIVE_MINIS_CAMERA=true`.
  final bool useNativeAndroidCamera;

  @override
  State<MinisIndependentCaptureScreen> createState() =>
      _MinisIndependentCaptureScreenState();
}

bool _pickedXFileIsVideo(XFile x) {
  final mt = x.mimeType?.toLowerCase();
  if (mt != null) {
    if (mt.startsWith('video/')) return true;
    if (mt.startsWith('image/')) return false;
  }
  final path = x.path.toLowerCase();
  const v = ['.mp4', '.mov', '.m4v', '.webm', '.mkv', '.3gp', '.avi', '.flv', '.wmv'];
  for (final ext in v) {
    if (path.endsWith(ext)) return true;
  }
  return false;
}

/// Some pickers return `file:///...` URIs; [File.exists] needs a real path.
String _normalizeLocalPickerPath(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  if (s.startsWith('file:')) {
    try {
      final filePath = Uri.parse(s).toFilePath();
      if (filePath.isNotEmpty) return filePath;
    } catch (_) {}
  }
  return s;
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

  /// Same sink as [_logMulticlip] — some devices drop unrelated [debugPrint] prefixes.
  void _logGallery(String message) => _logMulticlip('gallery: $message');

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
  /// Shown under the spinner when [_busy] is true (gallery, merge, camera ops).
  String _busyMessage = '';
  String? _error;
  bool _recording = false;
  String? _lastCapturePath;
  bool _lastCaptureIsVideo = false;
  bool _micEnabled = true;
  bool _railExpanded = true;
  MinisRecordCountdownMode _countdownMode = MinisRecordCountdownMode.off;
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
  int _nextClipId = 0;
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

  /// Zoom HUD badge: shown during a vertical drag gesture, auto-hides after
  /// the finger lifts. [_zoomBadgeTimer] cancels and resets visibility.
  bool _zoomBadgeVisible = false;
  Timer? _zoomBadgeTimer;

  /// When [minisMulticlipMergeSupported] is false, show a one-time banner.
  bool _mergeLimitedBannerDismissed = false;

  @override
  void initState() {
    super.initState();
    // Lock orientation to portrait when entering capture screen
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    if (kIsWeb) {
      _webUnsupported = true;
      _busy = false;
      _busyMessage = '';
      return;
    }
    _busyMessage = 'Starting camera…';
    if (widget.engine != null) {
      _engine = widget.engine;
    } else {
      _ownEngine = true;
    }
    unawaited(_boot());
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
            _busyMessage = '';
          });
        }
        return;
      }
    }

    try {
      if (widget.engine == null && _ownEngine && _engine == null) {
        _engine = await createMinisEngineAfterPermission(
          performanceMode: widget.cameraPerformanceMode,
          useNativeAndroidCamera: widget.useNativeAndroidCamera,
        );
      } else {
        await _engine!.initialize();
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = '';
        });
        unawaited(_syncZoomRangeFromEngine());
      }
      await _applyInitialMusicPrefillIfAny();
    } catch (e, st) {
      debugPrint('MinisIndependentCaptureScreen init failed: $e\n$st');
      if (mounted) {
        setState(() {
          _error = minisUserFriendlyException(e);
          _busy = false;
          _busyMessage = '';
        });
      }
    }
  }

  Future<void> _retryPermissionsFromDenied() async {
    if (widget.permissionPolicy != MinisCapturePermissionPolicy.request) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _permissionDenied = false;
      _busy = true;
      _busyMessage = 'Checking permissions…';
    });
    await _boot();
  }

  Future<void> _retryCameraInit() async {
    if (_webUnsupported) return;
    if (_engine == null) {
      // Engine factory failed during _boot(); re-run the full boot sequence.
      await _boot();
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
      _busyMessage = 'Starting camera…';
    });
    try {
      await _engine!.initialize();
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = '';
        });
        unawaited(_syncZoomRangeFromEngine());
      }
      await _applyInitialMusicPrefillIfAny();
    } catch (e, st) {
      debugPrint('MinisIndependentCaptureScreen retry init failed: $e\n$st');
      if (mounted) {
        setState(() {
          _error = minisUserFriendlyException(e);
          _busy = false;
          _busyMessage = '';
        });
      }
    }
  }

  Future<void> _showVideoOnlyImageDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Video only'),
        content: const Text(
          'This flow only accepts video. Choose a video from your library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  unawaited(_openGallery());
                }
              });
            },
            child: const Text('Choose video'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPhotoBlockedByReelSheet() async {
    final mergeSupported = minisMulticlipMergeSupported();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Photos and video clips',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  mergeSupported
                      ? 'You already have video clips. Merge your clips, remove the last clip, or keep recording video.'
                      : 'You already have video clips. Remove the last clip or keep recording video.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 20),
                if (mergeSupported) ...[
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      unawaited(_confirmClip());
                    },
                    child: const Text('Merge clips'),
                  ),
                  const SizedBox(height: 10),
                ],
                OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    unawaited(_deleteLastVideoClip());
                  },
                  child: const Text('Remove last clip'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        );
      },
    );
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
    // Stay portrait-up when leaving capture (host app is portrait-only).
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    _maxRecordTimer?.cancel();
    _holdStartTimer?.cancel();
    _clipElapsedTicker?.cancel();
    _zoomBadgeTimer?.cancel();

    // Async cleanup must be fire-and-forget (dispose is synchronous), but we
    // guard each call so platform callbacks arriving after teardown don't crash.
    unawaited(_disposeGuideMusic().catchError((_) {}));
    if (_ownEngine) {
      unawaited(_engine?.dispose().catchError((_) {}) ?? Future<void>.value());
    }
    super.dispose();
  }

  void _toast(String msg) {
    showMinisToast(context, msg);
  }

  void _applyBusy(bool loading, {String message = ''}) {
    if (!mounted) return;
    setState(() {
      _busy = loading;
      _busyMessage = loading ? message : '';
    });
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

  /// Copy a picker/temp music file to durable app storage so it survives
  /// until the background merge runs (picker temps are cleaned aggressively).
  Future<MinisMusicSegment> _persistMusicSegment(MinisMusicSegment seg) async {
    final src = File(seg.path);
    if (!await src.exists()) return seg;
    final dir = await getApplicationDocumentsDirectory();
    final musicDir = Directory(p.join(dir.path, 'minis_music'));
    if (!await musicDir.exists()) await musicDir.create(recursive: true);
    final ext = p.extension(seg.path).isNotEmpty ? p.extension(seg.path) : '.m4a';
    final dest = p.join(musicDir.path, 'music_${DateTime.now().microsecondsSinceEpoch}$ext');
    await src.copy(dest);
    return MinisMusicSegment(path: dest, startMs: seg.startMs, endMs: seg.endMs);
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
        return '0s';
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

  /// m:ss used / m:ss cap · clip count (always visible when reel has content).
  String get _reelTimePrimaryLine {
    final capMs = _sessionCapMs;
    final cap = minisFormatClipDurationLabel(capMs);
    if (_videoClips.isEmpty && !_recording) {
      return 'Max $cap';
    }
    final usedMs =
        _clipsTotalDurationMs + (_recording ? _liveClipElapsedMs : 0);
    final used = minisFormatClipDurationLabel(usedMs);
    final n = _videoClips.length;
    return '$used / $cap · $n clip${n == 1 ? '' : 's'}';
  }

  bool get _canConfirmClip =>
      (_videoClips.isNotEmpty ||
          (_lastCapturePath != null && _lastCapturePath!.isNotEmpty)) &&
      !_recording &&
      !_countingDown &&
      !_busy;

  String? get _emptyConfirmHint {
    if (_recording || _busy || _countingDown) return null;
    if (_canConfirmClip) return null;
    return 'Record or add a clip to finish';
  }

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
    var segment = MinisMusicSegment(
      path: selection.path,
      startMs: math.max(0, selection.startMs),
      endMs: math.max(selection.startMs, selection.endMs),
    );
    segment = await _persistMusicSegment(segment);
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
      segment = await _persistMusicSegment(segment);
      setState(() => _musicSegment = segment);
      await _prepareGuideMusic();
      _toast('Music ready - long-press Sounds to clear');
    } catch (e) {
      _toast('Music picker: $e');
    }
  }

  void _cycleSpeed() {
    if (_recording || _countingDown || _busy) return;
    // Bug 11 fix: speed is applied to ALL clips at merge time, not per-clip.
    // Allowing a speed change after the first clip is added would silently
    // re-encode earlier clips at the new rate, making them shorter/longer than
    // the user recorded. Block once the reel has content and explain why.
    if (_videoClips.isNotEmpty) {
      _toast(
        'Speed cannot be changed once clips are recorded. '
        'Remove all clips to pick a different speed.',
      );
      return;
    }
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
      final exists = await src.exists();
      _logGallery(
        'materialize exists=$exists srcLen=${sourcePath.length} '
        'tail=${sourcePath.length > 80 ? sourcePath.substring(sourcePath.length - 80) : sourcePath}',
      );
      if (!exists) return null;
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
      
      // Try an atomic rename (move) first. It's instant. The picker gives us a
      // cached temp file, so we own it and can move it. Copying a 500MB video
      // takes several seconds of blocking I/O and causes massive UI lag.
      try {
        final startRename = DateTime.now();
        await src.rename(dest.path);
        debugPrint('minis: materialize rename took ${DateTime.now().difference(startRename).inMilliseconds}ms');
      } catch (_) {
        // Fallback to full copy if cross-filesystem or permission issues.
        final startCopy = DateTime.now();
        debugPrint('minis: materialize rename failed, falling back to copy...');
        await src.copy(dest.path);
        debugPrint('minis: materialize copy took ${DateTime.now().difference(startCopy).inMilliseconds}ms');
        try {
          await src.delete(); // cleanup original if copy succeeds
        } catch (_) {}
      }
      
      final out = dest.path.replaceAll('\\', '/');
      _logGallery('materialize OK out=${p.basename(out)}');
      return out;
    } catch (e) {
      _logGallery('materialize failed: $e');
      return null;
    }
  }

  /// When [FilePicker] returns no filesystem path (or path is invalid), copy bytes/stream.
  Future<String?> _materializePlatformFileAsGallerySource(PlatformFile file) async {
    _logGallery(
      'platformFile name=${file.name} size=${file.size} pathNull=${file.path == null} ext=${file.extension}',
    );
    final path = file.path;
    if (path != null && path.isNotEmpty) {
      try {
        final n = _normalizeLocalPickerPath(path);
        final ok = await File(n).exists();
        _logGallery('platformFile path normalizedExists=$ok');
        if (ok) return n;
      } catch (e) {
        _logGallery('platformFile path error: $e');
      }
    }
    final stream = file.readStream;
    if (stream != null) {
      try {
        final base = await getApplicationDocumentsDirectory();
        final dir = Directory(p.join(base.path, 'loopit_minis_captures'));
        if (!await dir.exists()) await dir.create(recursive: true);
        final ext = (file.extension != null && file.extension!.isNotEmpty)
            ? '.${file.extension!}'
            : '.mp4';
        final dest = File(
          p.join(
            dir.path,
            'minis_gallery_pick_${DateTime.now().microsecondsSinceEpoch}$ext',
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
          _logGallery('stream copy empty or missing');
          return null;
        }
        _logGallery('stream copy OK ${p.basename(dest.path)}');
        return dest.path;
      } catch (e) {
        _logGallery('stream copy failed: $e');
        return null;
      }
    }
    final bytes = file.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      try {
        final base = await getApplicationDocumentsDirectory();
        final dir = Directory(p.join(base.path, 'loopit_minis_captures'));
        if (!await dir.exists()) await dir.create(recursive: true);
        final ext = (file.extension != null && file.extension!.isNotEmpty)
            ? '.${file.extension!}'
            : '.mp4';
        final dest = File(
          p.join(
            dir.path,
            'minis_gallery_pick_${DateTime.now().microsecondsSinceEpoch}$ext',
          ),
        );
        await dest.writeAsBytes(bytes, flush: true);
        _logGallery('bytes copy OK ${p.basename(dest.path)}');
        return dest.path;
      } catch (e) {
        _logGallery('bytes write failed: $e');
        return null;
      }
    }
    _logGallery('platformFile no path/stream/bytes');
    return null;
  }

  /// Resolves a [PlatformFile] from [FilePicker] to a local path [File] can open.
  Future<String?> _resolveLocalPathFromPlatformFile(PlatformFile f) async {
    final rawPath = f.path;
    String? src;
    if (rawPath != null && rawPath.isNotEmpty) {
      src = _normalizeLocalPickerPath(rawPath);
      _logGallery('resolvePlatformFile raw pathLen=${rawPath.length}');
      try {
        final ex = await File(src).exists();
        _logGallery('resolvePlatformFile normalized exists=$ex');
        if (!ex) src = null;
      } catch (e) {
        _logGallery('resolvePlatformFile File.exists error: $e');
        src = null;
      }
    } else {
      _logGallery('resolvePlatformFile no path — stream/bytes');
    }
    src ??= await _materializePlatformFileAsGallerySource(f);
    if (src == null || src.isEmpty) return null;
    _logGallery(
      'resolvePlatformFile tail=${src.length > 80 ? src.substring(src.length - 80) : src}',
    );
    return src;
  }

  /// Story / feed-style Minis (**!videoOnly**): [pickMedia] hangs or returns null on
  /// many Android devices; [FileType.media] matches photos + videos in one picker.
  ///
  /// Returns `true` if the flow finished here (success, cancel, or handled error).
  /// Returns `false` to fall back to [ImagePicker] (rare plugin failure).
  Future<bool> _openGalleryMixedMediaViaFilePicker() async {
    _logGallery('FilePicker(FileType.media) story/mixed');
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.media,
        allowMultiple: false,
        withReadStream: defaultTargetPlatform == TargetPlatform.android,
      );
      _logGallery(
        'FilePicker media back null=${result == null} count=${result?.files.length ?? 0}',
      );
      if (result == null || result.files.isEmpty) {
        _logGallery('FilePicker media cancel or empty');
        return true;
      }
      final f = result.files.single;
      final path = await _resolveLocalPathFromPlatformFile(f);
      if (path == null || path.isEmpty) {
        _logGallery('mixed pick could not resolve path');
        _toast('Could not read the selected file.');
        return true;
      }
      if (!mounted) return true;

      final isVideo = _pickedXFileIsVideo(XFile(path, name: f.name));
      _logGallery('mixed pick isVideo=$isVideo file=${p.basename(path)}');
      _logMulticlip(
        'picked path=${p.basename(path)} isVideo=$isVideo mime=(filePicker)',
      );

      if (!isVideo) {
        if (widget.videoOnly) {
          _logGallery('mixed pick returned non-video (videoOnly=true), rejecting');
          await _showVideoOnlyImageDialog();
          return true;
        }
        _logGallery('mixed pick returned image (videoOnly=false), proceeding with handoff');
        _deliverConfirmedCapture(path);
        return true;
      }

      await _importPickedGalleryVideoFromSourcePath(path);
      return true;
    } catch (e, st) {
      _logGallery('FilePicker media error: $e\n$st');
      return false;
    }
  }

  /// Minis / reels (**videoOnly**): use native file/video document picker. On many
  /// Android devices [ImagePicker.pickVideo] returns `null` even after the user
  /// picks a clip (Photo Picker / OEM quirks); [FilePicker] is reliable here.
  Future<void> _openGalleryVideoViaFilePicker() async {
    _logGallery('FilePicker(FileType.video) starting');
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
      // Android often omits [PlatformFile.path] for SAF URIs — stream still works.
      withReadStream: defaultTargetPlatform == TargetPlatform.android,
    );
    _logGallery(
      'FilePicker back null=${result == null} count=${result?.files.length ?? 0}',
    );
    if (result == null || result.files.isEmpty) {
      _logGallery('FilePicker cancel or empty');
      return;
    }
    final f = result.files.single;
    final src = await _resolveLocalPathFromPlatformFile(f);
    if (src == null || src.isEmpty) {
      _logGallery('no source after FilePicker');
      _toast('Could not read the selected file.');
      return;
    }
    
    // STRICT VERIFICATION: Reject if not identified as video
    if (!_pickedXFileIsVideo(XFile(src, name: f.name))) {
      _logGallery('FilePicker returned non-video, REJECTING');
      await _showVideoOnlyImageDialog();
      return;
    }

    await _importPickedGalleryVideoFromSourcePath(src);
  }

  Future<void> _importPickedGalleryVideoFromSourcePath(String sourcePath) async {
    if (!_pickedXFileIsVideo(XFile(sourcePath))) {
      _logGallery('importPickedGalleryVideo: REJECTED non-video path');
      await _showVideoOnlyImageDialog();
      return;
    }
    _logGallery(
      'import enter mergeSupported=${minisMulticlipMergeSupported()}',
    );
    _applyBusy(true, message: 'Saving video…');
    String? materialized;
    try {
      materialized = await _materializePickedVideoForPreview(sourcePath);
    } catch (e, st) {
      debugPrint('minis materialize: $e\n$st');
      if (mounted) {
        _toast(minisUserFriendlyException(e));
      }
      return;
    } finally {
      if (mounted) {
        _applyBusy(false);
      }
    }
    if (!mounted) {
      _logGallery('import ABORT not mounted after materialize');
      _logMulticlip('ABORT after materialize: not mounted');
      return;
    }
    if (materialized == null) {
      _logGallery('import REJECT materialized=null');
      _logMulticlip('REJECT: materialize copy failed (null path)');
      _toast('Could not read the selected video file.');
      return;
    }
    _logMulticlip('materialized to=${p.basename(materialized)}');
    _logGallery(
      'materialized ${p.basename(materialized)} len=${materialized.length}',
    );

    if (!minisMulticlipMergeSupported()) {
      _logGallery('single-clip → openMinisVideoPreview');
      final preview = await openMinisVideoPreview(context, materialized);
      _logGallery(
        'preview back null=${preview == null} path=${preview?.path != null ? p.basename(preview!.path) : 'n/a'}',
      );
      if (!mounted) {
        _logGallery('preview ABORT not mounted');
        try {
          await File(materialized).delete();
        } catch (_) {}
        return;
      }
      if (preview != null && preview.path.isNotEmpty) {
        _applyBusy(true, message: 'Adding clip…');
        try {
          await _appendGalleryVideoAfterPreview(
            preview.path,
            previewDurationMs: preview.durationMs,
          );
        } finally {
          if (mounted) {
            _applyBusy(false);
          }
        }
      } else {
        _logGallery('preview dismissed or empty');
        try {
          await File(materialized).delete();
        } catch (_) {}
        _toast('Video preview dismissed');
      }
      return;
    }

    _logGallery('multiclip → duration probe');
    final remainingMs =
        _sessionCapMs - _clipsTotalDurationMs - _liveClipElapsedMs;
    if (remainingMs < 500) {
      _toast('No time left.');
      try {
        await File(materialized).delete();
      } catch (_) {}
      return;
    }

    var clipMsProbe = 0;
    _applyBusy(true, message: 'Reading video…');
    try {
      clipMsProbe = await minisFinalizeClipDurationMs(
        0,
        materialized,
        fromGalleryFile: true,
      );
    } catch (e, st) {
      debugPrint('minis gallery probe: $e\n$st');
      if (mounted) {
        _toast(minisUserFriendlyException(e, context: 'duration'));
      }
      return;
    } finally {
      if (mounted) {
        _applyBusy(false);
      }
    }

    _logMulticlip(
      'gallery probe (pre-preview): clipMs=$clipMsProbe remainingBudgetMs=$remainingMs '
      'sessionCapMs=$_sessionCapMs usedMs=$_clipsTotalDurationMs',
    );

    if (clipMsProbe > 0 && clipMsProbe > remainingMs) {
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
        'Trim to ${remSec}s or less to add (${remSec}s left).',
      );
      if (!mounted) return;
      _applyBusy(true, message: 'Opening trim…');
      MinisReelTrimResult? trimOut;
      try {
        trimOut = await MinisReelClipTrimmerPage.open(
          context,
          File(materialized),
          maxOutputDuration: Duration(milliseconds: remainingMs),
        );
      } finally {
        if (mounted) {
          _applyBusy(false);
        }
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
        _toast('Trimmed segment is too long.');
        try {
          await File(trimOut.path).delete();
        } catch (_) {}
        try {
          await File(materialized).delete();
        } catch (_) {}
        return;
      }
      _applyBusy(true, message: 'Adding clip…');
      bool appended = false;
      try {
        appended = await _appendVideoSegment(
          trimOut.path,
          outMs,
          durationAlreadyFinalized: true,
        );
      } finally {
        if (mounted) {
          _applyBusy(false);
        }
      }
      if (trimOut.path != materialized) {
        try {
          await File(materialized).delete();
        } catch (_) {}
      }
      if (!appended) {
        try {
          await File(trimOut.path).delete();
        } catch (_) {}
      }
      return;
    }

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
      _applyBusy(true, message: 'Adding clip…');
      try {
        await _appendGalleryVideoAfterPreview(
          preview.path,
          previewDurationMs: preview.durationMs,
        );
      } finally {
        if (mounted) {
          _applyBusy(false);
        }
      }
      if (preview.path != materialized) {
        try {
          await File(materialized).delete();
        } catch (_) {}
      }
    } else {
      _logMulticlip('preview dismissed or empty result (preview=$preview)');
      try {
        await File(materialized).delete();
      } catch (_) {}
      _toast('Video preview dismissed');
    }
  }

  Future<Uint8List?> _thumbnailForVideoPath(
      String filePath,
      int durationMs,
    ) async {
    int capT(int t) {
      if (durationMs <= 1) return 0;
      final maxT = durationMs - 1;
      return t.clamp(0, maxT);
    }

    final times = <int>{};
    if (durationMs > 800) {
      times.add(capT((durationMs * 0.25).round()));
      times.add(capT((durationMs * 0.5).round()));
    }
    if (durationMs > 120) {
      times.add(capT(durationMs - 100));
    }
    times.add(400);
    times.add(0);

    for (final tMs in times) {
      try {
        final b = await VideoThumbnail.thumbnailData(
          video: filePath,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 480,
          quality: 88,
          timeMs: tMs,
        );
        if (b != null && b.isNotEmpty) {
          return b;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Appends [filePath] as the next segment of the reel.
  ///
  /// Returns `true` when the clip was added successfully, `false` when
  /// it was rejected (over cap, bad duration, etc.). Callers should delete
  /// any temp copies when `false` is returned (Bug 7 fix: orphan cleanup).
  Future<bool> _appendVideoSegment(
    String filePath,
    int durationMs, {
    bool trustGalleryPreviewDuration = false,
    /// When true, [durationMs] was already produced by [minisFinalizeClipDurationMs]
    /// (e.g. gallery-after-preview). Skips a second finalize pass — major latency win.
    bool durationAlreadyFinalized = false,
  }) async {
    _logMulticlip(
      '_appendVideoSegment enter path=${p.basename(filePath)} durationMs=$durationMs '
      'trustPreview=$trustGalleryPreviewDuration finalized=$durationAlreadyFinalized',
    );
    int useMs;
    try {
      if (durationAlreadyFinalized) {
        useMs = durationMs;
      } else {
        useMs = await minisFinalizeClipDurationMs(
          durationMs,
          filePath,
          fromGalleryPreview: trustGalleryPreviewDuration,
        );
      }
    } catch (e, st) {
      debugPrint('MINIS: _appendVideoSegment duration failed: $e\n$st');
      if (mounted) {
        _toast(minisUserFriendlyException(e, context: 'duration'));
      }
      return false;
    }
    
    debugPrint('MINIS: _appendVideoSegment got useMs=$useMs');

    if (useMs < 500) {
      debugPrint('MINIS: REJECTING because useMs ($useMs) < 500');
      int fileLen = 0;
      try {
        fileLen = await File(filePath).length();
      } catch (_) {}
      if (fileLen > 48 * 1024) {
        debugPrint('MINIS: File is large ($fileLen B), rejecting with toast');
        _logMulticlip(
          '_appendVideoSegment REJECT: useMs=$useMs is suspiciously short '
          'for a ${fileLen}B file — metadata not yet readable. Try again.',
        );
        if (mounted) {
          _toast(
            'Could not read clip length — try adding it again in a moment.',
          );
        }
        return false;
      } else {
        debugPrint('MINIS: File is small ($fileLen B), allowing short clip');
      }
    }

    if (_clipsTotalDurationMs + useMs > _sessionCapMs) {
      _toast("That clip exceeds the time limit.");
      return false;
    }
    final clipId = _nextClipId++;
    
    setState(() {
      _videoClips.add(
        MinisRecordingClip(
          id: clipId,
          path: filePath,
          durationMs: useMs,
          thumbnailBytes: null,
          speedAtRecord: _speedSteps[_speedIndex],
        ),
      );
      _clipsTotalDurationMs += useMs;
      _lastCapturePath = null;
    });
    
    _logMulticlipState('clip appended (total clips=${_videoClips.length})');
    _toast('Clip ${_videoClips.length} added (${minisFormatClipDurationLabel(useMs)})');
    
    // Fetch thumbnail asynchronously with a delay so we don't freeze the active camera!
    Future.delayed(const Duration(milliseconds: 1200), () async {
      Uint8List? thumb;
      try {
        thumb = await _thumbnailForVideoPath(filePath, useMs);
      } catch (e, st) {
        debugPrint('minis thumbnail: $e\n$st');
      }
      if (mounted && thumb != null) {
        setState(() {
          final idx = _videoClips.indexWhere((c) => c.id == clipId);
          if (idx >= 0) {
            _videoClips[idx] = MinisRecordingClip(
              id: clipId,
              path: filePath,
              durationMs: useMs,
              thumbnailBytes: thumb,
              speedAtRecord: _speedSteps[_speedIndex],
            );
          }
        });
      }
    });
    
    return true;
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
    _applyBusy(true, message: 'Opening trim…');
    MinisReelTrimResult? result;
    try {
      result = await MinisReelClipTrimmerPage.open(context, file);
    } finally {
      if (mounted) {
        _applyBusy(false);
      }
    }
    if (!mounted || result == null || result.path.isEmpty) return;
    try {
      // Trimmer span + file finalize (same ~1s probe issue as append).
      final newMs =
          await minisFinalizeClipDurationMs(result.durationMs, result.path);
      final delta = newMs - clip.durationMs;
      if (_clipsTotalDurationMs + delta > _sessionCapMs) {
        _toast("Trimmed clip exceeds the time limit.");
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
          id: clip.id,
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
      // Single finalize (was: BestEffort probe here + full finalize in append — doubled work).
      final previewMsArg = previewDurationMs;
      final reported =
          (previewMsArg != null && previewMsArg > 0) ? previewMsArg : 1;
          
      debugPrint('======================================');
      debugPrint('MINIS: _appendGalleryVideoAfterPreview');
      debugPrint('MINIS: previewDurationMs=$previewDurationMs, reported=$reported');
      debugPrint('======================================');
      
      final clipMs = await minisFinalizeClipDurationMs(
        reported,
        confirmedPath,
        fromGalleryPreview:
            previewDurationMs != null && previewDurationMs >= 3000,
        fromGalleryFile: true,
      );
      
      debugPrint('MINIS: clipMs returned from finalize=$clipMs');
      
      _logMulticlip(
        'duration after preview finalize: clipMs=$clipMs reported=$reported '
        'path=${p.basename(confirmedPath)}',
      );
      final used = _clipsTotalDurationMs;
      final cap = _sessionCapMs;
      final sum = used + clipMs;
      _logMulticlip(
        'duration (post-preview flow): newClipMs=$clipMs usedMs=$used '
        'capMs=$cap sumIfAdded=$sum',
      );
      if (clipMs <= 0) {
        debugPrint('MINIS: REJECTING DUE TO clipMs <= 0 (it is $clipMs)');
        _logMulticlip('REJECT: clipMs<=0 (metadata/probe failed)');
        _toast(
          'Could not read this video length. Try another file or export as MP4.',
        );
        return;
      }
      if (sum > cap) {
        debugPrint('MINIS: REJECTING DUE TO sum > cap ($sum > $cap)');
        _logMulticlip(
          'REJECT: over cap after preview (sum=$sum cap=$cap) — should be rare',
        );
        _toast('That clip exceeds the time limit. Try again.');
        return;
      }
      _logMulticlip('calling _appendVideoSegment');
      debugPrint('MINIS: calling _appendVideoSegment with $clipMs');
      await _appendVideoSegment(
        confirmedPath,
        clipMs,
        durationAlreadyFinalized: true,
      );
      _logMulticlip('_appendGalleryVideoAfterPreview OK');
    } catch (e, st) {
      _logMulticlip('REJECT: exception: $e\n$st');
      if (mounted) {
        _toast(minisUserFriendlyException(e, context: 'duration'));
      }
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
                            final durLabel =
                                minisFormatClipDurationLabel(clip.durationMs);
                            final trimSupported =
                                minisReelClipTrimmerPlatformSupported();
                            return Padding(
                              key: ValueKey<int>(clip.id),
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
                                    'Clip ${index + 1} · $durLabel',
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
    _logGallery(
      'open platform=$defaultTargetPlatform videoOnly=${widget.videoOnly} kIsWeb=$kIsWeb',
    );
    if (_busy || _recording || _countingDown) {
      _logGallery(
        'SKIP gate busy=$_busy rec=$_recording countdown=$_countingDown',
      );
      _logMulticlip(
        '_openGallery SKIP: busy=$_busy recording=$_recording countingDown=$_countingDown',
      );
      return;
    }
    if (kIsWeb) {
      _logGallery('web — not supported');
      _toast('Gallery is for Android / iOS builds.');
      return;
    }
    try {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        if (widget.videoOnly) {
          _logGallery('videoOnly enforcement → using FilePicker(video)');
          await _openGalleryVideoViaFilePicker();
          return;
        } else {
          _logGallery('mixed media allowed → trying FilePicker(media)');
          final handled = await _openGalleryMixedMediaViaFilePicker();
          if (handled) return;
        }
      }

      final picker = ImagePicker();
      XFile? x;

      try {
        _logGallery('picker selection starting videoOnly=${widget.videoOnly}');
        if (widget.videoOnly) {
          x = await picker.pickVideo(source: ImageSource.gallery);
        } else {
          // pickMedia is available on newer plugin versions
          x = await picker.pickMedia();
        }
        _logGallery('picker done null=${x == null}');
      } catch (e1) {
        _logMulticlip('primary picker failed ($e1) — trying fallbacks');
        try {
          x = await picker.pickVideo(source: ImageSource.gallery);
        } catch (e2) {
          if (widget.videoOnly) {
            _logMulticlip('videoOnly=true, pickVideo failed, ABORTING');
            if (mounted) _toast(minisUserFriendlyException(e2));
            return;
          }
          _logMulticlip('pickVideo failed, trying pickImage');
          try {
            x = await picker.pickImage(
              source: ImageSource.gallery,
              imageQuality: 92,
            );
          } catch (e3) {
            _logMulticlip('picker fully failed: $e1 / $e2 / $e3');
            if (mounted) {
              _toast(minisUserFriendlyException(e3));
            }
            return;
          }
        }
      }
      if (x == null) {
        _logGallery('ImagePicker result null (cancel or empty)');
        _logMulticlip('picker returned null (user cancelled)');
        return;
      }
      if (!mounted) {
        _logGallery('ABORT after pick not mounted');
        _logMulticlip('ABORT after pick: not mounted');
        return;
      }
      _logGallery('picked raw pathLen=${x.path.length} mime=${x.mimeType}');
      final path = _normalizeLocalPickerPath(x.path);
      if (path.isEmpty) {
        _logGallery('normalized path empty');
        if (mounted) {
          _toast('Could not read the selected file path.');
        }
        return;
      }
      final isVideo = _pickedXFileIsVideo(
        XFile(path, mimeType: x.mimeType, name: x.name),
      );
      if (isVideo) {
        _logGallery('picked video — importing');
        await _importPickedGalleryVideoFromSourcePath(path);
      } else {
        if (widget.videoOnly) {
          _logGallery('not a video (videoOnly=true) — blocking');
          await _showVideoOnlyImageDialog();
        } else {
          _logGallery('picked image (videoOnly=false) — delivering');
          _deliverConfirmedCapture(path);
        }
      }
    } catch (e, st) {
      _logMulticlip('Gallery error: $e\n$st');
      if (mounted) {
        _applyBusy(false);
        _toast(minisUserFriendlyException(e));
      }
    }
  }

  Future<void> _confirmClip() async {
    debugPrint(
      'MINIS_FLOW capture: confirm tapped clips=${_videoClips.length} '
      'lastPath=${_lastCapturePath ?? ''} isVideo=$_lastCaptureIsVideo',
    );
    if (_videoClips.isNotEmpty) {
      if (_busy || _recording || _countingDown) return;

      // STRICT PREVIEW: ALL CLIPS PASSTHROUGH (INSTANT)
      final rawPaths = _videoClips.map((c) => c.path).toList();
      final preview = await MinisVideoPreviewPage.open(
        context,
        rawPaths,
        title: 'Preview',
        confirmLabel: 'Next',
        allowReelTrim:
            minisReelClipTrimmerPlatformSupported() && rawPaths.length == 1,
        confirmOnClose: true,
        initialTotalDurationMs: _clipsTotalDurationMs,
      );
      if (!mounted) return;
      if (preview == null || preview.path.isEmpty) {
        return; // user cancelled preview
      }
      
      final postPreviewPath = preview.path;
      
      // NOW apply processing ONLY AFTER the user confirmed the preview.
      final hasMultipleClips = _videoClips.length > 1;
      final hasSpeedOrMusic = _speedSteps[_speedIndex] != 1.0 || _musicSegment != null;
      
      if (hasMultipleClips || hasSpeedOrMusic) {
        if (!minisMulticlipMergeSupported()) {
          _toast('Merging/Mixing requires Android, iOS, or macOS.');
          return;
        }
        
        // Pass the merge task back to the host app!
        // _deliverConfirmedCapture only accepts String, so we call the host
        // directly here — Object? is fine for completeCaptureResult.
        final pathsToMerge = hasMultipleClips ? rawPaths : [postPreviewPath];
        _videoClips.clear();
        _clipsTotalDurationMs = 0;

        final mergeRequest = MinisHandoffRequest(
          action: MinisHandoffAction.mergeRequired,
          clipPaths: pathsToMerge,
          playbackSpeed: _speedSteps[_speedIndex],
          enableAudio: _micEnabled,
          backgroundMusic: _musicSegment,
        );
        MinisCaptureHost.completeCaptureResult(mergeRequest.toMap());
        if (!mounted) return;
        final nav = Navigator.maybeOf(context, rootNavigator: true);
        if (nav != null && nav.canPop()) nav.pop();
        return;
      } else {
        // No processing needed. Deliver raw!
        _videoClips.clear();
        _clipsTotalDurationMs = 0;
        _deliverConfirmedCapture(postPreviewPath);
        return;
      }
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
          _applyBusy(true, message: 'Mixing audio…');
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
            if (mounted) {
              _applyBusy(false);
            }
            _deliverConfirmedCapture(merged);
          } catch (e) {
            if (mounted) {
              _toast('Mix failed. ${minisUserFriendlyException(e)}');
            }
          } finally {
            if (mounted) {
              _applyBusy(false);
            }
          }
          return;
        }
      }
    }

    _deliverConfirmedCapture(path);
  }

  Future<void> _deliverConfirmedCapture(String path) async {
    // Bug 10 fix: guard against stale _lastCapturePath from a previous
    // partial session (e.g. image edit cancelled mid-session). Delivering a
    // path that no longer exists would produce a bad upload with no feedback.
    try {
      if (!await File(path).exists()) {
        debugPrint('MINIS_FLOW capture: REJECT stale path — file missing: $path');
        if (mounted) {
          _toast(
            'The captured file is no longer available. Please capture again.',
          );
          setState(() {
            _lastCapturePath = null;
            _lastCaptureIsVideo = false;
          });
        }
        return;
      }
    } catch (e) {
      debugPrint('MINIS_FLOW capture: file-exists check failed: $e');
    }
    debugPrint('MINIS_FLOW capture: deliver confirmed path=$path');
    MinisCaptureHost.completeCaptureResult(path);
    debugPrint('MINIS_FLOW capture: host result completed');
    final cb = widget.onClipConfirmed;
    if (cb != null) {
      debugPrint('MINIS_FLOW capture: using host callback');
      cb(path);
      return;
    }
    // Guard: context access after async gap requires mounted check.
    if (!mounted) return;
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
      if (mounted) {
        _toast('Save failed. ${minisUserFriendlyException(e)}');
      }
    }
  }

  Future<void> _toggleMic() async {
    if (_recording || _busy || _countingDown) return;
    final eng = _engine;
    if (eng == null) return;
    final next = !_micEnabled;
    _applyBusy(true, message: 'Updating microphone…');
    try {
      await eng.setRecordWithAudio(next);
      if (mounted) setState(() => _micEnabled = next);
    } catch (e) {
      _toast('Mic setting failed. ${minisUserFriendlyException(e)}');
    } finally {
      if (mounted) {
        _applyBusy(false);
      }
    }
  }

  Future<void> _toggleTorch() async {
    if (_recording || _busy || _countingDown) return;
    final eng = _engine;
    if (eng == null) return;
    final wantOn = !eng.isTorchOn;
    _applyBusy(true, message: 'Updating flash…');
    try {
      await eng.setTorchEnabled(wantOn);
      if (mounted) setState(() {});
    } catch (e) {
      _toast('Flash not available on this lens.');
    } finally {
      if (mounted) {
        _applyBusy(false);
      }
    }
  }

  Future<void> _startRecordingInternal() async {
    final eng = _engine;
    if (eng == null || !eng.isInitialized || _recording) return;
    if (_clipsTotalDurationMs >= _sessionCapMs) {
      _toast('Time limit reached. Tap check to merge or remove a clip.');
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
      // unawaited(_syncZoomRangeFromEngine()); // Removed to prevent freeze on recording start
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
                  'Max time reached for this segment ($_speedRailLabel)',
            ),
          );
        }
      });
    } catch (e) {
      _activeClipStartedAt = null;
      _toast('Recording error. ${minisUserFriendlyException(e)}');
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
      setState(() => _recording = false);
      _applyBusy(true, message: 'Saving…');
      final path = await eng.stopRecording();
      if (!mounted) return;
      _zoomGesturePointer = null;
      if (path != null && path.isNotEmpty) {
        final d = math.max(1, rawElapsed);
        // Avoid probing duration on fresh camera clips — VideoPlayer init
        // freezes the active camera preview on many Android devices!
        await _appendVideoSegment(path, d, durationAlreadyFinalized: true);
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
      _toast('Stop failed. ${minisUserFriendlyException(e)}');
    } finally {
      if (mounted) {
        _applyBusy(false);
      }
    }
  }

  /// Loads device zoom bounds and applies the current [_zoomLevel] (clamped).
  /// Used after init, camera flip, and when recording starts so framing is kept.
  Future<void> _syncZoomRangeFromEngine() async {
    final eng = _engine;
    if (eng == null || !eng.isInitialized || !mounted) return;
    try {
      var lo = await eng.getMinZoomLevel();
      var hi = await eng.getMaxZoomLevel();
      if (!mounted) return;
      if (lo > hi) {
        final t = lo;
        lo = hi;
        hi = t;
      }
      final span = hi - lo;
      if (span < 1e-6) {
        if (mounted) {
          setState(() {
            _zoomMin = lo;
            _zoomMax = hi;
            _zoomLevel = lo;
          });
        }
        return;
      }
      final clamped = _zoomLevel.clamp(lo, hi);
      await eng.setZoomLevel(clamped);
      if (!mounted) return;
      setState(() {
        _zoomMin = lo;
        _zoomMax = hi;
        _zoomLevel = clamped;
      });
    } catch (_) {}
  }

  void _onPreviewZoomPointerDown(PointerDownEvent e) {
    if (_busy || _countingDown) return;
    // Bug 8 fix: if the shutter finger is already down (hold-to-record),
    // ignore new pointers on the preview area so zoom does not fire during
    // recording start (user adjusting grip can accidentally swipe).
    if (_shutterFingerDown) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    _zoomGesturePointer = e.pointer;
    _zoomPanStartY = e.localPosition.dy;
    _zoomPanStartLevel = _zoomLevel;
    // Show the zoom HUD badge when a gesture begins.
    if (mounted) setState(() => _zoomBadgeVisible = true);
    _zoomBadgeTimer?.cancel();
  }

  void _onPreviewZoomPointerMove(PointerMoveEvent e) {
    // Bug 8 fix: also skip move events while the shutter is held.
    if (_busy || _countingDown || _shutterFingerDown) return;
    if (e.pointer != _zoomGesturePointer) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    final span = _zoomMax - _zoomMin;
    if (span <= 1e-6) return;
    final h = MediaQuery.sizeOf(context).height;
    if (h <= 0) return;
    // Swipe up (smaller dy) → zoom in; swipe down → zoom out.
    final deltaY = e.localPosition.dy - _zoomPanStartY;
    const sensitivity = 1.75;
    final rawTarget =
        _zoomPanStartLevel - (deltaY / h) * span * sensitivity;
    final target = rawTarget.clamp(_zoomMin, _zoomMax);
    const smooth = 0.42;
    var next = _zoomLevel + (target - _zoomLevel) * smooth;
    if ((target - next).abs() < 0.0035) next = target;
    next = next.clamp(_zoomMin, _zoomMax);
    if ((next - _zoomLevel).abs() < 0.0015) return;
    _zoomLevel = next;
    unawaited(eng.setZoomLevel(next));
    if (mounted) setState(() {});
  }

  void _onPreviewZoomPointerUpOrCancel(PointerEvent e) {
    if (e.pointer == _zoomGesturePointer) {
      _zoomGesturePointer = null;
      // Auto-hide the zoom badge 1.8s after the gesture ends.
      _zoomBadgeTimer?.cancel();
      _zoomBadgeTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _zoomBadgeVisible = false);
      });
    }
  }

  void _onShutterPointerDown(PointerDownEvent event) {
    if (_busy || _countingDown) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized || _recording) return;
    if (_clipsTotalDurationMs >= _sessionCapMs) {
      _toast('Time limit reached.');
      return;
    }
    // Bug 8 fix: cancel any in-progress zoom gesture when the shutter goes
    // down. Without this, a grip-shift during the 280ms hold window would
    // continue moving zoom even though the preview Listener already ignores
    // the same pointer after _shutterFingerDown becomes true.
    _zoomGesturePointer = null;
    _zoomBadgeTimer?.cancel();
    if (_zoomBadgeVisible && mounted) {
      setState(() => _zoomBadgeVisible = false);
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
      _toast('Video only \u2014 hold to record.');
      return;
    }
    unawaited(_shutterShortTapPhoto());
  }

  Future<void> _shutterShortTapPhoto() async {
    if (_busy || _recording || _countingDown) return;
    if (_videoClips.isNotEmpty) {
      await _showPhotoBlockedByReelSheet();
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
    _applyBusy(true, message: 'Taking photo…');
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
      _toast('Photo error. ${minisUserFriendlyException(e)}');
    } finally {
      if (mounted) {
        _applyBusy(false);
      }
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
    _applyBusy(true, message: 'Switching camera…');
    try {
      await eng.switchCamera();
      if (mounted) {
        setState(() {});
        unawaited(_syncZoomRangeFromEngine());
      }
    } catch (e) {
      _toast('Flip failed. ${minisUserFriendlyException(e)}');
    } finally {
      if (mounted) {
        _applyBusy(false);
      }
    }
  }

  Widget _railAction({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Color? iconColor,
    VoidCallback? onLongPress,
    String? subtitle,
  }) {
    final disabled = onTap == null;
    final labelChild = subtitle == null
        ? Text(
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
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.62),
                  fontSize: 8,
                  height: 1.1,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          );
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
                  height: subtitle == null ? _kRailLabelSlotHeight : 40,
                  width: _kRailColumnWidth,
                  child: Center(child: labelChild),
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
        appBar: AppBar(title: const Text('Camera')),
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
        appBar: AppBar(title: const Text('Camera')),
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
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    await openAppSettings();
                  },
                  child: const Text('Open settings'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => unawaited(_retryPermissionsFromDenied()),
                  child: const Text('Try again'),
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
        appBar: AppBar(title: const Text('Camera')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.35),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => unawaited(_retryCameraInit()),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final eng = _engine;
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return PopScope(
      canPop: !_recording && _videoClips.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_recording) {
          _toast('Stop recording before leaving.');
          return;
        }
        // Has clips — confirm discard.
        showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Discard clips?'),
            content: Text(
              '${_videoClips.length} clip${_videoClips.length == 1 ? '' : 's'} '
              'will be lost.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ).then((discard) {
          if (discard == true && mounted) Navigator.of(context).pop();
        });
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          if (eng != null && !_busy)
            Positioned.fill(child: eng.buildPreview(context)),
          if (_busy)
            Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.8),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 64,
                            height: 64,
                            child: CircularProgressIndicator(
                              strokeWidth: 3.5,
                              color: Colors.white,
                              backgroundColor: Colors.white12,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            _busyMessage.isEmpty ? 'Please wait…' : _busyMessage,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (eng != null && !_busy && !_countingDown)
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
          // Bug 8 fix: zoom level HUD badge — shown during vertical drag gesture.
          // Appears at the left-centre of the preview and auto-fades after lift.
          if (!_busy && !_countingDown)
            Positioned(
              left: 12,
              bottom: 160,
              child: AnimatedOpacity(
                opacity: _zoomBadgeVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        () {
                          final v = _zoomLevel;
                          final s = v == v.roundToDouble()
                              ? v.toStringAsFixed(0)
                              : v.toStringAsFixed(1);
                          return '$s×';
                        }(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
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
          if (!kIsWeb &&
              !minisMulticlipMergeSupported() &&
              !_mergeLimitedBannerDismissed)
            Positioned(
              top: topPad + 46,
              left: 8,
              right: 8,
              child: Material(
                color: const Color(0xE6B45309),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Multi-clip merge is not available on this system. '
                          'Use one take or finish on Android, iOS, or Mac.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.95),
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        icon: const Icon(Icons.close, color: Colors.white, size: 20),
                        onPressed: () => setState(
                          () => _mergeLimitedBannerDismissed = true,
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
                      subtitle: _musicSegment != null ? 'Long-press: clear' : null,
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
                            _reelTimePrimaryLine,
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
                                    ? 'Hold to record · ${(_remainingSessionMs / 1000).ceil()}s left · gallery (left)'
                                    : 'Hold to record video')
                                : (_videoClips.isNotEmpty
                                    ? 'Hold to add · ${(_remainingSessionMs / 1000).ceil()}s left · tap photo · gallery (left)'
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
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 112),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              if (_videoClips.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    'Merge clips',
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.7),
                                      fontSize: 11,
                                    ),
                                  ),
                                )
                              else if (_lastCapturePath != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    _lastCaptureIsVideo ? 'Video' : 'Photo',
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white
                                          .withValues(alpha: 0.7),
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
                            if (_emptyConfirmHint != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                _emptyConfirmHint!,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 10,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ],
                          ),
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
    ),
    );
  }
}
