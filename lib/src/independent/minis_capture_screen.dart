import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:loopit_minis/src/audio/minis_audio_player.dart';
import 'package:loopit_minis/src/audio/minis_audio_session.dart';
import 'package:loopit_minis/src/sys/paths.dart';
import 'package:loopit_minis/src/sys/permissions.dart';
import 'package:loopit_minis/src/sys/picker.dart';
import 'package:loopit_minis/src/sys/wakelock.dart';

import 'package:loopit_minis/src/videdit/videdit_engine.dart';
import 'package:loopit_minis/src/videdit/videdit_types.dart';
import 'package:loopit_minis/src/independent/deepar_camera_engine.dart';
import 'package:loopit_minis/src/independent/minis_camera_engine_factory.dart';
import 'package:loopit_minis/src/independent/minis_deepar_catalog.dart';
import 'package:loopit_minis/src/independent/minis_native_permissions.dart';
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
import 'package:loopit_minis/src/session_and_toast.dart';
import 'package:loopit_minis/src/minis_capture_host.dart';
import 'package:loopit_minis/src/minis_capture_ports.dart';
import 'package:loopit_minis/src/minis_log.dart';
import 'package:loopit_minis/src/minis_user_message.dart';

/// Framing guides drawn over the preview. Engine still records its native
/// aspect — these letterbox/safe-area overlays guide composition only.
enum MinisAspectRatio {
  full, // engine native; no letterbox
  r9x16,
  r4x5,
  r1x1,
}

extension _MinisAspectRatioMath on MinisAspectRatio {
  double? get ratio {
    switch (this) {
      case MinisAspectRatio.full:
        return null;
      case MinisAspectRatio.r9x16:
        return 9 / 16;
      case MinisAspectRatio.r4x5:
        return 4 / 5;
      case MinisAspectRatio.r1x1:
        return 1.0;
    }
  }

  String get shortLabel {
    switch (this) {
      case MinisAspectRatio.full:
        return 'Full';
      case MinisAspectRatio.r9x16:
        return '9:16';
      case MinisAspectRatio.r4x5:
        return '4:5';
      case MinisAspectRatio.r1x1:
        return '1:1';
    }
  }
}

/// White-balance presets exposed by the rail. `auto` clears manual WB and
/// lets the engine pick; named presets pass a kelvin value to `setManual`.
enum MinisWhiteBalancePreset {
  auto,
  tungsten,
  fluorescent,
  daylight,
  cloudy,
}

extension _MinisWhiteBalancePresetMeta on MinisWhiteBalancePreset {
  String get label {
    switch (this) {
      case MinisWhiteBalancePreset.auto:
        return 'Auto';
      case MinisWhiteBalancePreset.tungsten:
        return 'Tungsten';
      case MinisWhiteBalancePreset.fluorescent:
        return 'Fluor';
      case MinisWhiteBalancePreset.daylight:
        return 'Daylight';
      case MinisWhiteBalancePreset.cloudy:
        return 'Cloudy';
    }
  }

  int? get kelvin {
    switch (this) {
      case MinisWhiteBalancePreset.auto:
        return null;
      case MinisWhiteBalancePreset.tungsten:
        return 3200;
      case MinisWhiteBalancePreset.fluorescent:
        return 4000;
      case MinisWhiteBalancePreset.daylight:
        return 5500;
      case MinisWhiteBalancePreset.cloudy:
        return 6500;
    }
  }

  IconData get icon {
    switch (this) {
      case MinisWhiteBalancePreset.auto:
        return Icons.wb_auto;
      case MinisWhiteBalancePreset.tungsten:
        return Icons.wb_incandescent;
      case MinisWhiteBalancePreset.fluorescent:
        return Icons.wb_iridescent;
      case MinisWhiteBalancePreset.daylight:
        return Icons.wb_sunny;
      case MinisWhiteBalancePreset.cloudy:
        return Icons.wb_cloudy;
    }
  }
}

/// Process-lifetime UI preference cache for the capture screen. Survives
/// re-entry into the screen during the same app session. Not persistent
/// to disk — host apps that want disk persistence should wrap.
class MinisCaptureSessionPrefs {
  MinisCaptureSessionPrefs._();
  static MinisCaptureSessionPrefs instance = MinisCaptureSessionPrefs._();

  MinisAspectRatio aspectRatio = MinisAspectRatio.r9x16;
  bool gridVisible = false;
  MinisRecordCountdownMode countdownMode = MinisRecordCountdownMode.off;
}

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
/// [NativeAndroidMinisCameraEngine], no Retrytech).
///
/// **Hold** the shutter to start recording video — once recording is armed
/// you can release; recording continues until you **tap** the shutter (now
/// showing a stop icon) to stop. **Short tap** takes a photo unless
/// **videoOnly** is set (host “Minis / reel” flows — video only). **Swipe
/// up/down on the preview** to zoom in/out anytime the camera is idle or while
/// recording (device support via [MinisCameraEnginePort] zoom). Each
/// completed video (tap-to-stop after hold) **appends** a segment (LoopIt-style
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

  /// If null, a [NativeAndroidMinisCameraEngine] is created and disposed by this
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

  /// Selects preview/capture resolution for the default native engine.
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

bool _pickedPathIsVideo(String path, {String? mime}) {
  final mt = mime?.toLowerCase();
  if (mt != null && mt.isNotEmpty) {
    if (mt.startsWith('video/')) return true;
    if (mt.startsWith('image/')) return false;
  }
  final p = path.toLowerCase();
  const v = ['.mp4', '.mov', '.m4v', '.webm', '.mkv', '.3gp', '.avi', '.flv', '.wmv'];
  for (final ext in v) {
    if (p.endsWith(ext)) return true;
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
    extends State<MinisIndependentCaptureScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const double _kRailIconSize = 25;
  static const double _kCornerBtnSize = 48;
  static const double _kCornerIconSize = 22;
  static const double _kAppBarIconSize = 26;
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

  /// Active DeepAR filter — null means CameraX engine is running normally.
  DeepArFilter? _activeFilter;
  /// True while a DeepAR engine is mounted in [_engine] in place of CameraX.
  bool _filterMode = false;
  /// Re-entrancy guard for filter swap (dispose → init crossing).
  bool _filterSwapping = false;
  bool _permissionDenied = false;
  // Which permission(s) the denial screen should name, and whether the OS
  // will even re-prompt ("Don't allow" → only Settings can fix it).
  bool _permCameraDenied = false;
  bool _permMicDenied = false;
  bool _permPermanentlyDenied = false;
  bool _busy = true;
  /// Shown under the spinner when [_busy] is true (gallery, merge, camera ops).
  String _busyMessage = '';
  String? _error;
  bool _recording = false;
  String? _lastCapturePath;
  bool _lastCaptureIsVideo = false;
  bool _micEnabled = true;
  bool _railExpanded = true;
  late MinisRecordCountdownMode _countdownMode;
  bool _countingDown = false;
  int? _countdownTick;
  Timer? _maxRecordTimer;
  Timer? _holdStartTimer;
  bool _shutterFingerDown = false;
  bool _holdVideoArmed = false;
  bool _recordingLocked = false;
  bool _lockReadyToEngage = false;
  bool _pendingStopTap = false;
  double _shutterPointerStartDx = 0;
  double _lockDragProgress = 0;
  static const double _kLockTriggerDistance = 72;
  late final AnimationController _lockPulseController;
  late final AnimationController _recordPulseController;
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
  double _zoomPanStartY = 0;
  double _zoomPanStartLevel = 1.0;

  /// Zoom HUD badge: shown during a vertical drag gesture, auto-hides after
  /// the finger lifts. [_zoomBadgeTimer] cancels and resets visibility.
  bool _zoomBadgeVisible = false;
  Timer? _zoomBadgeTimer;

  /// When [minisMulticlipMergeSupported] is false, show a one-time banner.
  bool _mergeLimitedBannerDismissed = false;

  /// Rule-of-thirds composition grid overlay. Off by default; toggled via the
  /// right-rail Grid action and persisted only for this session.
  late bool _gridVisible;

  /// Low-budget haptic markers fired during recording. Each Duration in this
  /// set is consumed once per recording session so the same milestone never
  /// double-pings (the elapsed ticker runs at 50ms cadence).
  final Set<int> _lowBudgetHapticsFired = <int>{};

  /// Accumulated pinch scale during the current zoom gesture. 1.0 = unchanged.
  double _pinchAccumulatedScale = 1.0;
  double _pinchStartZoomLevel = 1.0;
  bool _zoomScaleActive = false;

  /// Visible tap-to-focus reticle. Null = hidden. Position is in local preview
  /// coordinates; the painter centers itself on this point.
  Offset? _focusReticleAt;

  /// True while AE/AF lock is engaged (long-press on preview). Pure UI hint;
  /// cleared on next tap. Engine doesn't expose a lock API yet.
  bool _aeAfLocked = false;
  late final AnimationController _focusReticleController;
  Timer? _focusReticleHideTimer;

  /// Selected framing aspect ratio. UI-only overlay (engine still records its
  /// native aspect); presentation/letterbox is applied here.
  late MinisAspectRatio _aspectRatio;

  /// Whether the shutter coachmark has been shown this session. Soft-persisted
  /// for the lifetime of the screen — first-launch UX hint only.
  bool _shutterCoachmarkDismissed = false;
  Timer? _shutterCoachmarkTimer;

  /// Engine capability snapshot loaded once during boot. Default = empty caps,
  /// which keeps all extended-feature rails hidden until probed.
  MinisCameraCapabilities _caps = const MinisCameraCapabilities();

  /// HDR10 capture toggle — rail visible only when caps.hdr10.
  bool _hdrEnabled = false;

  /// Slow-mo FPS selection. -1 = off / standard. Cycles through caps.slowMoFps.
  /// Rail visible only when caps.slowMoFps is non-empty.
  int _slowMoFpsIdx = -1;

  /// White-balance preset. Rail visible only when caps.manualWb is true.
  MinisWhiteBalancePreset _wb = MinisWhiteBalancePreset.auto;

  /// Live audio levels meter (peak/rms) while recording with mic on.
  MinisAudioLevels? _liveAudioLevels;
  StreamSubscription<MinisAudioLevels>? _audioLevelsSub;
  StreamSubscription<MinisEngineEvent>? _stateSub;

  /// Set when a recoverable in-progress recording was detected on boot.
  /// We surface a one-shot dialog rather than auto-recovering.
  bool _recoveryPromptShown = false;

  /// Exposure bias in EV. Engines without exposure control silently ignore.
  /// Visible after tap-to-focus alongside the reticle.
  double _exposureBias = 0;
  static const double _kExposureMin = -2.0;
  static const double _kExposureMax = 2.0;
  Timer? _exposureSliderHideTimer;
  bool _exposureSliderVisible = false;

  @override
  void initState() {
    super.initState();
    // Hydrate UI prefs from the session-scoped store so re-entering camera
    // keeps last-used framing/grid/countdown — no disk I/O.
    final prefs = MinisCaptureSessionPrefs.instance;
    _aspectRatio = prefs.aspectRatio;
    _gridVisible = prefs.gridVisible;
    _countdownMode = prefs.countdownMode;
    // Observe app lifecycle so locking the device / sending the app to the
    // background stops an in-progress recording. Without this the camera
    // preview pauses but the underlying recorder keeps capturing audio.
    WidgetsBinding.instance.addObserver(this);
    // Keep the screen awake on the capture surface so the display timeout
    // doesn't lock the device mid-recording, which would pause the camera
    // and abort the clip. Disabled in dispose.
    unawaited(NativeWakelock.enable());
    _lockPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
    _recordPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _focusReticleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
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
    unawaited(_manageAudioSession(true));
    // Warm the VidEdit capability cache so the multi-clip banner reflects
    // actual engine state instead of the cold-cache "unavailable" default.
    unawaited(MinisVidEdit.instance.isAvailable().then((_) {
      if (mounted) setState(() {});
    }).catchError((_) {}));
  }

  Future<void> _manageAudioSession(bool active) async {
    try {
      final session = await AudioSession.instance;
      if (active) {
        await session.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.duckOthers,
          avAudioSessionMode: AVAudioSessionMode.videoRecording,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        ));
        await session.setActive(true);
      } else {
        await session.setActive(false);
      }
    } catch (e) {
      debugPrint('MINIS: AudioSession error: $e');
    }
  }

  Future<void> _boot() async {
    if (_webUnsupported) return;

    if (widget.permissionPolicy == MinisCapturePermissionPolicy.request) {
      final cam = await Permission.camera.request();
      final mic = await Permission.microphone.request();
      if (!cam.isGranted || !mic.isGranted) {
        MinisLog.w(
          'capture permission denied: camera=${cam.name} mic=${mic.name}',
        );
        if (mounted) {
          setState(() {
            _permissionDenied = true;
            _permCameraDenied = !cam.isGranted;
            _permMicDenied = !mic.isGranted;
            _permPermanentlyDenied =
                cam.isPermanentlyDenied || mic.isPermanentlyDenied;
            _busy = false;
            _busyMessage = '';
          });
        }
        return;
      }
    }

    try {
      // Let the previous capture's camera finish releasing before grabbing
      // it again (the platform frees it asynchronously after dispose).
      final pending = _pendingEngineDispose;
      if (pending != null) {
        await pending.timeout(const Duration(seconds: 3), onTimeout: () {});
        if (identical(pending, _pendingEngineDispose)) {
          _pendingEngineDispose = null;
        }
      }
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
        unawaited(_probeEngineCapabilities());
        _subscribeAudioLevels();
        _subscribeEngineStateStream();
        unawaited(_maybePromptRecovery());
        _armShutterCoachmarkAutoDismiss();
      }
      await _applyInitialMusicPrefillIfAny();
    } catch (e, st) {
      MinisLog.w('capture engine init failed', e, st);
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
                  'Video clip recorded',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'You already have a video clip. Tap Next (✓) to continue, or remove the clip to take a photo.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    unawaited(_confirmClip());
                  },
                  child: const Text('Next'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    unawaited(_deleteLastVideoClip());
                  },
                  child: const Text('Remove clip'),
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
    await _autoMuteMicForMusic();
    await _prepareGuideMusic();
  }

  /// Camera teardown is async on the platform side; opening the next capture
  /// before the previous engine finished releasing can hit "camera in use"
  /// errors. dispose() parks its future here and the next _boot awaits it.
  static Future<void>? _pendingEngineDispose;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(NativeWakelock.disable());
    // Restore to all orientations when leaving capture.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);

    _maxRecordTimer?.cancel();
    _holdStartTimer?.cancel();
    _clipElapsedTicker?.cancel();
    _zoomBadgeTimer?.cancel();
    _exposureSliderHideTimer?.cancel();
    unawaited(_audioLevelsSub?.cancel());
    _audioLevelsSub = null;
    unawaited(_stateSub?.cancel());
    _stateSub = null;
    _shutterCoachmarkTimer?.cancel();
    _lockPulseController.dispose();
    _recordPulseController.dispose();
    _focusReticleController.dispose();
    _focusReticleHideTimer?.cancel();
    unawaited(_manageAudioSession(false));
    unawaited(_disposeGuideMusic().catchError((_) {}));
    if (_ownEngine) {
      final eng = _engine;
      if (eng != null) {
        final f = eng.dispose().catchError((Object e) {
          MinisLog.w('capture engine dispose failed', e);
        });
        _pendingEngineDispose = f;
        unawaited(f);
      }
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Device lock / app backgrounded → finalize any active recording so the
    // recorder (audio + video) is fully released. Without this the camera
    // preview pauses on lock but the audio source keeps capturing.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      if (_recording) {
        unawaited(_stopRecordingInternal());
      }
    }
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

  Future<void> _deleteMusicSegmentFile(MinisMusicSegment? seg) async {
    if (seg == null) return;
    try {
      final f = File(seg.path);
      if (await f.exists() && seg.path.contains('/minis_music/')) {
        await f.delete();
        debugPrint('minis: deleted old music file: ${seg.path}');
      }
    } catch (e) {
      debugPrint('minis: failed to delete old music file: $e');
    }
  }

  Future<void> _clearMusic() async {
    if (_recording || _busy || _countingDown) return;
    await _pauseGuideMusic();
    await _disposeGuideMusic();
    final oldSeg = _musicSegment;
    if (mounted) setState(() => _musicSegment = null);
    await _deleteMusicSegmentFile(oldSeg);
    _toast('Music cleared');
  }

  /// Recorded clips / picked music live only in this State — popping the
  /// screen discards them, so leaving must be confirmed.
  bool get _hasUnsavedCapture =>
      _videoClips.isNotEmpty || _musicSegment != null;

  Future<void> _confirmExitCapture() async {
    if (!mounted) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard your recording?'),
        content: Text(
          _videoClips.isEmpty
              ? 'Your selected music will be lost.'
              : 'You recorded ${_videoClips.length} '
                  'clip${_videoClips.length == 1 ? '' : 's'}. '
                  'Going back will delete '
                  '${_videoClips.length == 1 ? 'it' : 'them'}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      Navigator.of(context).pop();
    }
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

  double get _recordRingProgress {
    final cap = math.max(1, _sessionCapMs);
    final used = (_clipsTotalDurationMs + (_recording ? _liveClipElapsedMs : 0))
        .clamp(0, cap);
    return used / cap;
  }

  /// Duration label shown above the shutter.
  String get _reelTimePrimaryLine {
    final capMs = _sessionCapMs;
    final cap = minisFormatClipDurationLabel(capMs);
    if (_videoClips.isEmpty && !_recording) {
      return 'Max $cap';
    }
    final usedMs =
        _clipsTotalDurationMs + (_recording ? _liveClipElapsedMs : 0);
    final used = minisFormatClipDurationLabel(usedMs);
    return '$used / $cap';
  }

  bool get _canConfirmClip =>
      (_videoClips.isNotEmpty ||
          (_lastCapturePath != null && _lastCapturePath!.isNotEmpty)) &&
      !_recording &&
      !_countingDown &&
      !_busy;

  bool get _hasUnsavedCapture =>
      _videoClips.isNotEmpty ||
      (_lastCapturePath != null && _lastCapturePath!.isNotEmpty);

  /// PopScope callback when system-back is pressed and we blocked the pop.
  /// Confirms via dialog; pops on confirm.
  Future<void> _handleExitAttempt() async {
    if (!mounted) return;
    if (_recording) {
      _toast('Stop recording before leaving.');
      return;
    }
    if (_countingDown) {
      _cancelCountdown();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text(
          'Discard clip?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Leaving now will discard the clip you recorded.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      final nav = Navigator.maybeOf(context);
      if (nav != null && nav.canPop()) nav.pop();
    }
  }

  String? get _emptyConfirmHint {
    if (_recording || _busy || _countingDown) return null;
    if (_canConfirmClip) return null;
    return 'Record or add a clip to finish';
  }

  Future<String?> _normalizePickedFilePath(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final n = path.replaceAll('\\', '/');
      if (await File(n).exists()) return n;
    } catch (_) {}
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
    await _autoMuteMicForMusic();
    await _prepareGuideMusic();
    _toast('Music ready - long-press Sounds to clear');
    return true;
  }

  /// Copy a picker/temp music file to durable app storage so it survives
  /// until the background merge runs (picker temps are cleaned aggressively).
  Future<MinisMusicSegment> _persistMusicSegment(MinisMusicSegment seg) async {
    final src = File(seg.path);
    if (!await src.exists()) return seg;
    final dirPath = await NativePaths.documentsDir();
    if (dirPath == null) return seg;
    final musicDir = Directory(NativePaths.join([dirPath, 'minis_music']));
    if (!await musicDir.exists()) await musicDir.create(recursive: true);
    final extRaw = NativePaths.extension(seg.path);
    final ext = extRaw.isNotEmpty ? extRaw : '.m4a';
    final dest = NativePaths.join([musicDir.path, 'music_${DateTime.now().microsecondsSinceEpoch}$ext']);
    await src.copy(dest);
    
    // Proactively clean up the old file
    if (_musicSegment != null && _musicSegment!.path != dest) {
      await _deleteMusicSegmentFile(_musicSegment);
    }
    
    return MinisMusicSegment(path: dest, startMs: seg.startMs, endMs: seg.endMs);
  }

  Future<void> _pickMusic() async {
    if (kIsWeb || _busy || _recording || _countingDown) return;
    if (_musicSegment != null) {
      _toast('Only one music can be selected.');
      return;
    }
    try {
      final handledByHost = await _pickMusicFromHostIfAvailable();
      if (handledByHost) return;

      final existing = _musicSegment;
      if (minisAudioWaveformsTrimSupported() &&
          existing != null &&
          await File(existing.path).exists()) {
        if (!mounted) return;
        var segment = await showMinisMusicTimingSheet(
          context,
          audioPath: existing.path,
          sessionCapMs: _sessionCapMs,
          initialStartMs: existing.startMs,
        );
        if (!mounted) return;
        if (segment == null) return;
        segment = await _persistMusicSegment(segment);
        setState(() => _musicSegment = segment);
        await _autoMuteMicForMusic();
        await _prepareGuideMusic();
        _toast('Music section updated - long-press Sounds to clear');
        return;
      }

      final r = await NativePicker.pickFile(
        multi: false,
        extensions: kMinisAudioFileExtensions,
      );
      if (!mounted) return;
      if (r.isEmpty) return;
      final file = r.first;
      final path = await _normalizePickedFilePath(file.path);
      if (!mounted) return;
      if (path == null || path.isEmpty) {
        _toast('Could not read that audio file. Try another one.');
        return;
      }
      final ext = NativePaths.extension(path).toLowerCase().replaceFirst('.', '');
      if (!kMinisAudioFileExtensions.contains(ext)) {
        _toast('Please choose an audio file.');
        return;
      }
      if (!mounted) return;
      var segment = await showMinisMusicTimingSheet(
        context,
        audioPath: path,
        sessionCapMs: _sessionCapMs,
      );
      if (!mounted) return;
      if (segment == null) return;
      segment = await _persistMusicSegment(segment);
      setState(() => _musicSegment = segment);
      await _autoMuteMicForMusic();
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
        'Speed cannot be changed after recording. '
        'Remove the clip to pick a different speed.',
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

  Future<void> _pickSpeed() async {
    if (_recording || _countingDown || _busy) return;
    if (_videoClips.isNotEmpty) {
      _toast(
        'Speed cannot be changed after recording. '
        'Remove the clip to pick a different speed.',
      );
      return;
    }
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _SpeedSheet(
        steps: _speedSteps,
        activeIndex: _speedIndex,
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == _speedIndex) return;
    setState(() => _speedIndex = picked);
    HapticFeedback.selectionClick();
    _toast(
      'Record cap ${_effectiveMaxRecording.inSeconds}s at $_speedRailLabel.',
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
    MinisCaptureSessionPrefs.instance.countdownMode = _countdownMode;
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
      final basePath = await NativePaths.documentsDir();
      if (basePath == null) return null;
      final dir = Directory(NativePaths.join([basePath, 'loopit_minis_captures']));
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = NativePaths.extension(sourcePath).toLowerCase();
      final safe = (ext.isNotEmpty && ext.length <= 8) ? ext : '.mp4';
      final dest = File(
        NativePaths.join([
          dir.path,
          'minis_gallery_in_${DateTime.now().microsecondsSinceEpoch}$safe',
        ]),
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
      _logGallery('materialize OK out=${NativePaths.basename(out)}');
      return out;
    } catch (e, st) {
      MinisLog.w('gallery video materialize failed', e, st);
      _logGallery('materialize failed: $e');
      return null;
    }
  }

  /// Story / feed-style Minis (**!videoOnly**): mixed photos+videos in one picker.
  /// Returns `true` if the flow finished here.
  Future<bool> _openGalleryMixedMediaViaFilePicker() async {
    _logGallery('NativePicker.pickMedia story/mixed');
    try {
      final items = await NativePicker.pickMedia(multi: false, types: const ['image', 'video']);
      _logGallery('NativePicker media count=${items.length}');
      if (items.isEmpty) {
        _logGallery('NativePicker media cancel or empty');
        return true;
      }
      final f = items.first;
      final path = await _normalizePickedFilePath(f.path);
      if (path == null || path.isEmpty) {
        _logGallery('mixed pick could not resolve path');
        _toast('Could not read the selected file.');
        return true;
      }
      if (!mounted) return true;

      final isVideo = _pickedPathIsVideo(path, mime: f.mime);
      _logGallery('mixed pick isVideo=$isVideo file=${NativePaths.basename(path)}');
      _logMulticlip(
        'picked path=${NativePaths.basename(path)} isVideo=$isVideo mime=${f.mime}',
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
      _logGallery('NativePicker media error: $e\n$st');
      return false;
    }
  }

  /// Reels (**videoOnly**): native video picker.
  Future<void> _openGalleryVideoViaFilePicker() async {
    _logGallery('NativePicker.pickVideo starting');
    final picked = await NativePicker.pickVideo();
    _logGallery('NativePicker.pickVideo back null=${picked == null}');
    if (picked == null) {
      _logGallery('NativePicker.pickVideo cancel');
      return;
    }
    final src = await _normalizePickedFilePath(picked.path);
    if (src == null || src.isEmpty) {
      _logGallery('no source after NativePicker.pickVideo');
      _toast('Could not read the selected file.');
      return;
    }

    if (!_pickedPathIsVideo(src, mime: picked.mime)) {
      _logGallery('NativePicker returned non-video, REJECTING');
      await _showVideoOnlyImageDialog();
      return;
    }

    await _importPickedGalleryVideoFromSourcePath(src);
  }

  Future<void> _importPickedGalleryVideoFromSourcePath(String sourcePath) async {
    if (!_pickedPathIsVideo(sourcePath)) {
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
      MinisLog.w('gallery import materialize threw', e, st);
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
    _logMulticlip('materialized to=${NativePaths.basename(materialized)}');
    _logGallery(
      'materialized ${NativePaths.basename(materialized)} len=${materialized.length}',
    );

    if (!minisMulticlipMergeSupported()) {
      _logGallery('single-clip → openMinisVideoPreview');
      final preview = await openMinisVideoPreview(context, materialized);
      _logGallery(
        'preview back null=${preview == null} path=${preview?.path != null ? NativePaths.basename(preview!.path) : 'n/a'}',
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
        'preview confirmed path=${NativePaths.basename(preview.path)} '
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

    // Phase 1: thumbnails come from the native VidEdit engine; returns null
    // when the engine is not built into this binary so the caller falls back
    // to a placeholder tile.
    if (!MinisVidEdit.instance.isAvailableSync) return null;
    for (final tMs in times) {
      try {
        final b = await MinisVidEdit.instance.thumbnailAt(
          path: filePath,
          atMs: tMs,
          width: 480,
          height: 480,
        );
        if (b != null && b.isNotEmpty) {
          return b;
        }
      } on VidEditUnsupportedError {
        return null;
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
      '_appendVideoSegment enter path=${NativePaths.basename(filePath)} durationMs=$durationMs '
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

    // Allow a 1-second buffer on iOS for timer jitter and system latency during stopRecording.
    final buffer = defaultTargetPlatform == TargetPlatform.iOS ? 1000 : 0;
    if (_clipsTotalDurationMs + useMs > _sessionCapMs + buffer) {
      _toast("That clip no longer fits this mini's time limit.");
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
    late final MinisRecordingClip removed;
    setState(() {
      removed = _videoClips.removeLast();
      _clipsTotalDurationMs =
          math.max(0, _clipsTotalDurationMs - removed.durationMs);
    });
    try {
      final f = File(removed.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _toast('Removed last clip');
  }


  /// [previewDurationMs]: when the clip was just confirmed from [MinisVideoPreviewPage],
  /// pass the player-reported duration (avoids repeated ~1s file probes on MP4s).
  Future<void> _appendGalleryVideoAfterPreview(
    String confirmedPath, {
    int? previewDurationMs,
  }) async {
    _logMulticlip(
      '_appendGalleryVideoAfterPreview enter confirmed=${NativePaths.basename(confirmedPath)} '
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
        'path=${NativePaths.basename(confirmedPath)}',
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
    // Single-clip mode: block gallery when a clip is already recorded.
    if (_videoClips.isNotEmpty) {
      _toast('Tap ✓ to use this clip, or ↩ to remove it first.');
      return;
    }
    if (kIsWeb) {
      _logGallery('web — not supported');
      _toast('Gallery is for Android / iOS builds.');
      return;
    }
    // The system picker can take seconds to appear on slow devices; show the
    // busy overlay immediately so the tap visibly registered. The finally
    // below clears it once the picker is done unless a later stage (import /
    // save) has already replaced it with its own message.
    _applyBusy(true, message: 'Opening gallery…');
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

      PickedItem? x;
      try {
        _logGallery('NativePicker selection starting videoOnly=${widget.videoOnly}');
        if (widget.videoOnly) {
          x = await NativePicker.pickVideo();
        } else {
          final items = await NativePicker.pickMedia(multi: false);
          if (items.isNotEmpty) x = items.first;
        }
        _logGallery('NativePicker done null=${x == null}');
      } catch (e1) {
        _logMulticlip('NativePicker failed ($e1)');
        if (mounted) _toast(minisUserFriendlyException(e1));
        return;
      }
      if (x == null) {
        _logGallery('NativePicker result null (cancel or empty)');
        _logMulticlip('picker returned null (user cancelled)');
        return;
      }
      if (!mounted) {
        _logGallery('ABORT after pick not mounted');
        _logMulticlip('ABORT after pick: not mounted');
        return;
      }
      _logGallery('picked raw pathLen=${x.path.length} mime=${x.mime}');
      final path = _normalizeLocalPickerPath(x.path);
      if (path.isEmpty) {
        _logGallery('normalized path empty');
        if (mounted) {
          _toast('Could not read the selected file path.');
        }
        return;
      }
      final isVideo = _pickedPathIsVideo(path, mime: x.mime);
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
      MinisLog.w('gallery pick failed', e, st);
      _logMulticlip('Gallery error: $e\n$st');
      if (mounted) {
        _applyBusy(false);
        _toast(minisUserFriendlyException(e));
      }
    } finally {
      if (mounted && _busy && _busyMessage == 'Opening gallery…') {
        _applyBusy(false);
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

      final rawPaths = _videoClips.map((c) => c.path).toList();
      final hasMultipleClips = _videoClips.length > 1;
      final speed = _speedSteps[_speedIndex];
      final hasSpeed = speed != 1.0;
      final hasMusic = _musicSegment != null;
      final isMuted = !_micEnabled;

      String pathForPreview = rawPaths.first;
      int durationForPreview = _clipsTotalDurationMs;

      // If we need any processing (merge, speed, music, or mute), do it NOW
      // so the preview screen shows the final result.
      if (hasMultipleClips || hasSpeed || hasMusic || isMuted) {
        if (!minisMulticlipMergeSupported()) {
          _toast('Merging/Mixing requires Android, iOS, or macOS.');
          return;
        }
        _applyBusy(true, message: 'Preparing preview…');
        try {
          final merged = await mergeMinisVideoClipsWithDialog(
            context: context,
            clipPaths: rawPaths,
            playbackSpeed: speed,
            enableAudio: _micEnabled,
            backgroundMusic: _musicSegment,
          );
          if (!mounted) return;
          _applyBusy(false);
          if (merged == null || merged.isEmpty) return;

          pathForPreview = merged;
          if (hasSpeed) {
            durationForPreview = (durationForPreview / speed).round();
          }
        } catch (e) {
          if (mounted) _applyBusy(false);
          _toast('Processing failed: ${minisUserFriendlyException(e)}');
          return;
        }
      }

      final preview = await MinisVideoPreviewPage.open(
        context,
        [pathForPreview],
        title: 'Preview',
        confirmLabel: 'Next',
        allowReelTrim: minisReelClipTrimmerPlatformSupported(),
        confirmOnClose: true,
        initialTotalDurationMs: durationForPreview,
        musicSegment: _musicSegment,
      );
      if (!mounted) return;
      if (preview == null || preview.path.isEmpty) {
        return; // user cancelled preview
      }

      // Preview confirmed (possibly trimmed).
      // Since we already merged/mixed before preview, we just deliver the result.
      final finalPath = preview.path;
      _videoClips.clear();
      _clipsTotalDurationMs = 0;

      // Deliver to host app
      final request = MinisHandoffRequest(
        action: MinisHandoffAction.none,
        path: finalPath,
        backgroundMusic: _musicSegment,
      );
      MinisCaptureHost.completeCaptureResult(request.toMap());
      if (mounted) {
        final nav = Navigator.maybeOf(context, rootNavigator: true);
        if (nav != null && nav.canPop()) {
          nav.pop(request.toMap());
        } else {
          // Capture screen rendered as the root route (typical for the
          // standalone example app). There's nothing to pop to, so hand the
          // final path to the per-screen confirmation callback instead, so
          // host apps that wire `onClipConfirmed` get a redirect to the
          // editor screen.
          widget.onClipConfirmed?.call(finalPath);
        }
      }
      return;
    }

    if (_lastCapturePath != null && _lastCapturePath!.isNotEmpty) {
      _deliverConfirmedCapture(_lastCapturePath!);
    }
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
      final dirPath = await NativePaths.documentsDir();
      if (dirPath == null) return;
      final sub = Directory(NativePaths.join([dirPath, 'minis_captures']));
      if (!await sub.exists()) {
        await sub.create(recursive: true);
      }
      final ext = NativePaths.extension(sourcePath);
      final name =
          'minis_${DateTime.now().millisecondsSinceEpoch}${ext.isEmpty ? '' : ext}';
      final dest = File(NativePaths.join([sub.path, name]));
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
    // Block unmute attempts while music is active to prevent double-audio
    // (mic capturing the speaker-played music guide track).
    if (next && _musicSegment != null) {
      _toast('Microphone is muted while music is active.');
      return;
    }
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

  /// Auto-mute the mic when music is selected so the recorder does not capture
  /// the speaker-played music guide alongside ambient noise, which would later
  /// double up against the pure music track at merge/preview time.
  ///
  /// Wrapped in [_applyBusy] because `setRecordWithAudio` tears down and
  /// re-initializes the [CameraController]; without hiding the preview the
  /// in-flight `CameraPreview` widget can still reference the disposed
  /// controller and throw "buildPreview() was called on a disposed
  /// CameraController" mid-reinit.
  Future<void> _autoMuteMicForMusic() async {
    if (!_micEnabled) return;
    final eng = _engine;
    if (eng == null) {
      if (mounted) setState(() => _micEnabled = false);
      return;
    }
    _applyBusy(true, message: 'Muting microphone for music…');
    try {
      await eng.setRecordWithAudio(false);
      if (mounted) setState(() => _micEnabled = false);
    } catch (e) {
      debugPrint('minis: auto-mute mic for music failed: $e');
    } finally {
      if (mounted) _applyBusy(false);
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

  Future<void> _pickWhiteBalance() async {
    if (_recording || _countingDown || _busy) return;
    final picked = await showModalBottomSheet<MinisWhiteBalancePreset>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _WhiteBalanceSheet(active: _wb),
    );
    if (picked == null || !mounted || picked == _wb) return;
    final eng = _engine;
    if (eng == null) return;
    _applyBusy(true, message: 'Setting ${picked.label} white balance…');
    try {
      await eng.setManual(wbKelvin: picked.kelvin);
      if (mounted) setState(() => _wb = picked);
      HapticFeedback.selectionClick();
    } catch (e) {
      _toast('WB error: ${minisUserFriendlyException(e)}');
    } finally {
      if (mounted) _applyBusy(false);
    }
  }

  Future<void> _toggleHdr() async {
    if (_recording || _countingDown || _busy) return;
    final eng = _engine;
    if (eng == null) return;
    final want = !_hdrEnabled;
    _applyBusy(true, message: want ? 'Enabling HDR…' : 'Disabling HDR…');
    try {
      final ok = await eng.enableHdr(want);
      if (mounted) setState(() => _hdrEnabled = ok && want);
      if (!ok && want) _toast('HDR not available on this lens.');
    } catch (e) {
      _toast('HDR error: ${minisUserFriendlyException(e)}');
    } finally {
      if (mounted) _applyBusy(false);
    }
  }

  Future<void> _cycleSlowMo() async {
    if (_recording || _countingDown || _busy) return;
    final list = _caps.slowMoFps;
    if (list.isEmpty) return;
    final eng = _engine;
    if (eng == null) return;
    final nextIdx = _slowMoFpsIdx + 1 >= list.length ? -1 : _slowMoFpsIdx + 1;
    final targetFps = nextIdx < 0 ? 0 : list[nextIdx];
    _applyBusy(
      true,
      message: nextIdx < 0
          ? 'Returning to normal speed…'
          : 'Switching to ${list[nextIdx]} fps…',
    );
    try {
      final res = await eng.enableSlowMo(targetFps);
      if (!mounted) return;
      if (nextIdx < 0 || res.enabled) {
        setState(() => _slowMoFpsIdx = nextIdx);
        _toast(nextIdx < 0 ? 'Slow-mo off' : 'Slow-mo ${res.actualFps} fps');
      } else {
        _toast('Slow-mo unavailable at that frame rate');
      }
    } catch (e) {
      _toast('Slow-mo error: ${minisUserFriendlyException(e)}');
    } finally {
      if (mounted) _applyBusy(false);
    }
  }

  /// Auto-dismiss the shutter coachmark after 6 seconds so first-time users
  /// who explore the rail or gallery aren't blocked by it forever.
  void _armShutterCoachmarkAutoDismiss() {
    if (_shutterCoachmarkDismissed) return;
    _shutterCoachmarkTimer?.cancel();
    _shutterCoachmarkTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || _shutterCoachmarkDismissed) return;
      setState(() => _shutterCoachmarkDismissed = true);
    });
  }

  Future<void> _probeEngineCapabilities() async {
    final eng = _engine;
    if (eng == null) return;
    try {
      final c = await eng.getCapabilities();
      if (!mounted) return;
      setState(() => _caps = c);
    } catch (e) {
      debugPrint('MINIS: getCapabilities failed: $e');
    }
  }

  void _subscribeEngineStateStream() {
    _stateSub?.cancel();
    final eng = _engine;
    if (eng == null) return;
    try {
      _stateSub = eng.stateStream.listen(
        (event) {
          if (!mounted) return;
          if (event.state == MinisEngineState.error) {
            final msg = event.message ?? 'Camera engine reported an error.';
            _toast(msg);
            setState(() {
              _error = msg;
              _recording = false;
              _busy = false;
            });
          }
        },
        onError: (e) {
          debugPrint('MINIS: stateStream listener error: $e');
        },
      );
    } catch (e) {
      debugPrint('MINIS: stateStream subscribe failed: $e');
    }
  }

  Future<void> _maybePromptRecovery() async {
    if (_recoveryPromptShown) return;
    final eng = _engine;
    if (eng == null) return;
    MinisRecoveryInfo? info;
    try {
      info = await eng.probeRecovery();
    } catch (e) {
      debugPrint('MINIS: probeRecovery failed: $e');
      return;
    }
    if (info == null || !mounted) return;
    _recoveryPromptShown = true;
    final wantRecover = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text(
          'Recover unfinished clip?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'A recording was interrupted. Recover it now, or discard.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Recover'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (wantRecover == true) {
      _applyBusy(true, message: 'Recovering clip…');
      try {
        final path = await eng.recoverAndFinalize();
        if (!mounted) return;
        if (path != null && path.isNotEmpty) {
          await _appendVideoSegment(path, 0, durationAlreadyFinalized: false);
          _toast('Recovered last recording.');
        } else {
          _toast('Nothing recoverable from previous session.');
        }
      } catch (e) {
        _toast('Recovery failed: ${minisUserFriendlyException(e)}');
      } finally {
        if (mounted) _applyBusy(false);
      }
    } else {
      try {
        await eng.discardRecovery();
      } catch (e) {
        debugPrint('MINIS: discardRecovery failed: $e');
      }
    }
  }

  void _subscribeAudioLevels() {
    _audioLevelsSub?.cancel();
    final eng = _engine;
    if (eng == null) return;
    try {
      _audioLevelsSub = eng.audioLevelsStream.listen(
        (lv) {
          if (!mounted) return;
          if (!_recording || !_micEnabled) {
            if (_liveAudioLevels != null) {
              setState(() => _liveAudioLevels = null);
            }
            return;
          }
          setState(() => _liveAudioLevels = lv);
        },
        onError: (_) {},
      );
    } catch (e) {
      debugPrint('MINIS: audioLevelsStream subscribe failed: $e');
    }
  }

  /// Fires a light haptic at predetermined remaining-time milestones (5s, 3s,
  /// 1s) before the session cap. Each milestone fires at most once per take.
  void _emitLowBudgetHapticsIfNeeded() {
    final remainingMs =
        _sessionCapMs - _clipsTotalDurationMs - _liveClipElapsedMs;
    if (remainingMs <= 0) return;
    const milestonesMs = <int>[5000, 3000, 1000];
    for (final ms in milestonesMs) {
      if (remainingMs <= ms && !_lowBudgetHapticsFired.contains(ms)) {
        _lowBudgetHapticsFired.add(ms);
        HapticFeedback.lightImpact();
      }
    }
  }

  Future<void> _startRecordingInternal() async {
    final eng = _engine;
    if (eng == null || !eng.isInitialized || _recording) return;
    // Single-clip mode: only one clip allowed. If a clip already exists,
    // prompt the user to confirm (✓) or undo (↩) first.
    if (_videoClips.isNotEmpty) {
      _toast('Tap ✓ to use this clip, or ↩ to remove it and record again.');
      return;
    }
    if (_clipsTotalDurationMs >= _sessionCapMs) {
      _toast('Time limit reached. Tap ✓ to continue or ↩ to remove the clip.');
      return;
    }
    final budgetMs = _sessionCapMs - _clipsTotalDurationMs;
    final cap = Duration(milliseconds: math.max(1, budgetMs));
    try {
      await eng.startRecording();
      if (!mounted) return;
      _activeClipStartedAt = DateTime.now();
      _clipBudgetMsAtRecordStart = budgetMs;
      // Hide transient HUD overlays so they don't obscure the recording.
      _focusReticleHideTimer?.cancel();
      _exposureSliderHideTimer?.cancel();
      _focusReticleAt = null;
      _exposureSliderVisible = false;
      _zoomBadgeVisible = false;
      setState(() => _recording = true);
      // unawaited(_syncZoomRangeFromEngine()); // Removed to prevent freeze on recording start
      unawaited(_startGuideMusicForRecording());
      unawaited(_ensureGuideMusicPlayingAfterRecordStart());
      _clipElapsedTicker?.cancel();
      _lowBudgetHapticsFired.clear();
      _clipElapsedTicker =
          Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted || !_recording) return;
        _emitLowBudgetHapticsIfNeeded();
        setState(() {});
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
    _recordingLocked = false;
    _lockReadyToEngage = false;
    _holdVideoArmed = false;
    _shutterFingerDown = false;
    _pendingStopTap = false;
    _lockDragProgress = 0;
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
      final rawPath = await eng.stopRecording();
      if (!mounted) return;
      if (rawPath != null && rawPath.isNotEmpty) {
        // iOS: The camera plugin saves to tmp/ which is inaccessible to
        // AVAssetExportSession during composition (OSStatus error -12660).
        // Copy to Documents/loopit_minis_captures/ first on iOS.
        String path = rawPath;
        if (defaultTargetPlatform == TargetPlatform.iOS &&
            rawPath.contains('/tmp/')) {
          try {
            final basePath = await NativePaths.documentsDir();
            if (basePath == null) {
              throw StateError('documents dir unavailable');
            }
            final dir =
                Directory(NativePaths.join([basePath, 'loopit_minis_captures']));
            if (!await dir.exists()) await dir.create(recursive: true);
            final ext = NativePaths.extension(rawPath);
            final dest = NativePaths.join([
              dir.path,
              'minis_cam_${DateTime.now().microsecondsSinceEpoch}$ext',
            ]);
            await File(rawPath).copy(dest);
            path = dest;
            try {
              await File(rawPath).delete();
            } catch (_) {}
          } catch (copyErr) {
            debugPrint('MINIS: tmp→docs copy failed: $copyErr — using raw path');
            path = rawPath;
          }
        }
        final d = math.max(1, rawElapsed);
        // Wall-clock from start/stop is authoritative for camera clips.
        // Skip the slow re-probe loop (cost up to ~10s on short clips when
        // file metadata reports the placeholder ~1s).
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

  void _onPreviewScaleStart(ScaleStartDetails d) {
    if (_busy || _countingDown) return;
    if (_shutterFingerDown) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    _zoomPanStartY = d.focalPoint.dy;
    _zoomPanStartLevel = _zoomLevel;
    _pinchStartZoomLevel = _zoomLevel;
    _pinchAccumulatedScale = 1.0;
    _zoomScaleActive = true;
    if (mounted) setState(() => _zoomBadgeVisible = true);
    _zoomBadgeTimer?.cancel();
  }

  void _onPreviewScaleUpdate(ScaleUpdateDetails d) {
    if (_busy || _countingDown || _shutterFingerDown) return;
    if (!_zoomScaleActive) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    final span = _zoomMax - _zoomMin;
    if (span <= 1e-6) return;

    final isPinch = d.pointerCount >= 2;
    double rawTarget;
    if (isPinch) {
      // Multi-touch pinch: scale relative to the level at pinch start.
      _pinchAccumulatedScale = d.scale.clamp(0.05, 50.0);
      rawTarget =
          (_pinchStartZoomLevel * _pinchAccumulatedScale).clamp(_zoomMin, _zoomMax);
    } else {
      // Single-finger vertical drag: swipe up = zoom in.
      final h = MediaQuery.sizeOf(context).height;
      if (h <= 0) return;
      final deltaY = d.focalPoint.dy - _zoomPanStartY;
      const sensitivity = 1.75;
      rawTarget =
          _zoomPanStartLevel - (deltaY / h) * span * sensitivity;
    }
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

  void _onPreviewScaleEnd(ScaleEndDetails d) {
    _zoomScaleActive = false;
    _zoomBadgeTimer?.cancel();
    _zoomBadgeTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _zoomBadgeVisible = false);
    });
  }

  /// Tap on the preview → animated focus reticle + engine focus call. We use
  /// normalized [0,1] coordinates so engines independent of preview size can
  /// translate to native sensor coordinates. Suppressed in filter mode since
  /// the DeepAR engine doesn't implement tap-to-focus.
  Future<void> _onPreviewTapToFocus(TapUpDetails d, Size canvasSize) async {
    if (_busy || _countingDown) return;
    if (_filterMode) return;
    if (_aeAfLocked) {
      _toast('AE/AF unlocked');
      setState(() => _aeAfLocked = false);
      return;
    }
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    final w = canvasSize.width;
    final h = canvasSize.height;
    if (w <= 0 || h <= 0) return;
    final nx = (d.localPosition.dx / w).clamp(0.0, 1.0);
    final ny = (d.localPosition.dy / h).clamp(0.0, 1.0);
    setState(() {
      _focusReticleAt = d.localPosition;
    });
    _focusReticleController
      ..reset()
      ..forward();
    HapticFeedback.selectionClick();
    _showExposureSlider();
    _focusReticleHideTimer?.cancel();
    _focusReticleHideTimer = Timer(const Duration(milliseconds: 1100), () {
      if (!mounted) return;
      setState(() => _focusReticleAt = null);
    });
    try {
      await eng.tapToFocus(x: nx, y: ny);
    } catch (e) {
      debugPrint('MINIS: tapToFocus failed: $e');
    }
  }

  /// Long-press on preview → lock AE/AF visually. Pure UI flag (engine port
  /// has no lock API yet); cleared by next tap.
  void _onPreviewLongPressToLock(LongPressStartDetails d, Size canvasSize) {
    if (_busy || _countingDown || _filterMode) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    final w = canvasSize.width;
    final h = canvasSize.height;
    if (w <= 0 || h <= 0) return;
    final nx = (d.localPosition.dx / w).clamp(0.0, 1.0);
    final ny = (d.localPosition.dy / h).clamp(0.0, 1.0);
    setState(() {
      _focusReticleAt = d.localPosition;
      _aeAfLocked = true;
    });
    _focusReticleController
      ..reset()
      ..forward();
    _focusReticleHideTimer?.cancel();
    HapticFeedback.mediumImpact();
    _toast('AE/AF locked — tap to unlock');
    try {
      unawaited(eng.tapToFocus(x: nx, y: ny));
    } catch (_) {}
  }

  /// Make the EV slider visible for ~3.2s; re-arm timer on each interaction.
  void _showExposureSlider() {
    _exposureSliderHideTimer?.cancel();
    if (!_exposureSliderVisible && mounted) {
      setState(() => _exposureSliderVisible = true);
    }
    _exposureSliderHideTimer = Timer(const Duration(milliseconds: 3200), () {
      if (!mounted) return;
      setState(() => _exposureSliderVisible = false);
    });
  }

  Future<void> _onExposureBiasChanged(double next) async {
    var clamped = next.clamp(_kExposureMin, _kExposureMax).toDouble();
    // Snap to zero when within 0.1 EV so users land at neutral cleanly.
    if (clamped.abs() < 0.1) clamped = 0.0;
    if ((clamped - _exposureBias).abs() < 0.01) return;
    setState(() => _exposureBias = clamped);
    _showExposureSlider();
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    try {
      await eng.setExposureBias(clamped);
    } catch (e) {
      debugPrint('MINIS: setExposureBias failed: $e');
    }
  }

  /// Bottom-sheet picker for the framing guide. Long-press the rail action to
  /// quick-cycle instead (see [_cycleAspectRatio]).
  Future<void> _pickAspectRatio() async {
    if (_recording || _countingDown || _busy) return;
    final picked = await showModalBottomSheet<MinisAspectRatio>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _AspectRatioSheet(active: _aspectRatio),
    );
    if (picked == null || !mounted) return;
    if (picked == _aspectRatio) return;
    setState(() => _aspectRatio = picked);
    MinisCaptureSessionPrefs.instance.aspectRatio = picked;
    HapticFeedback.selectionClick();
  }

  /// Cycle UI framing guide (rail long-press shortcut).
  void _cycleAspectRatio() {
    if (_recording || _countingDown) return;
    const order = MinisAspectRatio.values;
    final idx = order.indexOf(_aspectRatio);
    final next = order[(idx + 1) % order.length];
    setState(() => _aspectRatio = next);
    MinisCaptureSessionPrefs.instance.aspectRatio = next;
    HapticFeedback.selectionClick();
  }

  /// Jump zoom to a preset multiplier (e.g. 1x, 2x). Clamped to engine range.
  Future<void> _setZoomPreset(double level) async {
    if (_busy || _countingDown) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    final span = _zoomMax - _zoomMin;
    if (span <= 1e-6) return;
    final target = level.clamp(_zoomMin, _zoomMax).toDouble();
    if ((target - _zoomLevel).abs() < 0.005) return;
    _zoomLevel = target;
    try {
      await eng.setZoomLevel(target);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _zoomBadgeVisible = true;
    });
    HapticFeedback.selectionClick();
    _zoomBadgeTimer?.cancel();
    _zoomBadgeTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _zoomBadgeVisible = false);
    });
  }

  void _onShutterPointerDown(PointerDownEvent event) {
    if (_busy || _countingDown) return;
    final eng = _engine;
    if (eng == null || !eng.isInitialized) return;
    if (!_shutterCoachmarkDismissed) {
      _shutterCoachmarkDismissed = true;
    }
    // Already recording (hands-free locked): mark this press as tap-to-stop;
    // actual stop fires on PointerUp so a quick press cancels cleanly.
    if (_recording) {
      _pendingStopTap = true;
      return;
    }
    if (_clipsTotalDurationMs >= _sessionCapMs) {
      _toast('Recording limit reached.');
      return;
    }
    _zoomScaleActive = false;
    _zoomBadgeTimer?.cancel();
    if (_zoomBadgeVisible && mounted) {
      setState(() => _zoomBadgeVisible = false);
    }

    _holdStartTimer?.cancel();
    _shutterFingerDown = true;
    _holdVideoArmed = false;
    _lockReadyToEngage = false;
    _recordingLocked = false;
    _lockDragProgress = 0;
    _shutterPointerStartDx = event.localPosition.dx;
    _holdStartTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted || !_shutterFingerDown) return;
      _holdVideoArmed = true;
      // Recording starts while finger is still down. Lock indicator is
      // displayed; dragging finger upward past _kLockTriggerDistance engages
      // hands-free lock so recording continues after release.
      HapticFeedback.lightImpact();
      unawaited(_startRecordingInternal());
      if (mounted) setState(() {});
    });
  }

  void _onShutterPointerMove(PointerMoveEvent event) {
    if (!_shutterFingerDown) return;
    if (!_holdVideoArmed || !_recording || _recordingLocked) return;
    final dx = event.localPosition.dx - _shutterPointerStartDx;
    final progress = (-dx / _kLockTriggerDistance).clamp(0.0, 1.0);
    if (dx <= -_kLockTriggerDistance) {
      _recordingLocked = true;
      _shutterFingerDown = false;
      _holdVideoArmed = false;
      _lockReadyToEngage = false;
      _lockDragProgress = 1.0;
      HapticFeedback.mediumImpact();
      _toast('Hands-free recording — tap shutter to stop.');
      if (mounted) setState(() {});
      return;
    }
    final nowHot = dx <= -_kLockTriggerDistance * 0.55;
    final progressChanged = (progress - _lockDragProgress).abs() > 0.02;
    if (nowHot != _lockReadyToEngage || progressChanged) {
      _lockReadyToEngage = nowHot;
      _lockDragProgress = progress;
      if (mounted) setState(() {});
    }
  }

  void _onShutterPointerUpOrCancel({bool cancelled = false}) {
    _holdStartTimer?.cancel();
    _holdStartTimer = null;
    final wasHold = _holdVideoArmed;
    _shutterFingerDown = false;
    _holdVideoArmed = false;
    final wasReadyHint = _lockReadyToEngage;
    _lockReadyToEngage = false;
    if (_pendingStopTap) {
      _pendingStopTap = false;
      if (!cancelled && _recording) {
        unawaited(_stopRecordingInternal());
      }
      return;
    }
    if (_recordingLocked) {
      // Lock-engage gesture release: keep recording running hands-free.
      if (mounted && wasReadyHint) setState(() {});
      return;
    }
    if (wasHold && _recording) {
      // Hold-to-record release without lock: stop recording.
      unawaited(_stopRecordingInternal());
      return;
    }
    if (_recording) {
      unawaited(_stopRecordingInternal());
      return;
    }
    if (cancelled) return;
    if (widget.videoOnly) {
      _toast('Video only — hold to record.');
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
        if (i <= 3) {
          HapticFeedback.selectionClick();
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!mounted) return;
      HapticFeedback.mediumImpact();
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
        child: Semantics(
          button: true,
          label: subtitle == null ? label : '$label, $subtitle',
          enabled: !disabled,
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
                      child: Icon(
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
                    child: Icon(
                      _railExpanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
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

  Widget _buildRecordingStopIcon() {
    return AnimatedBuilder(
      animation: _recordPulseController,
      builder: (context, child) {
        final t = _recordPulseController.value;
        final scale = 0.86 + 0.14 * t;
        final glow = 0.35 + 0.45 * t;
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: _kShutterStopIconSize + 14,
              height: _kShutterStopIconSize + 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.redAccent.withValues(alpha: glow * 0.55),
                    blurRadius: 14 + 8 * t,
                    spreadRadius: 1.5,
                  ),
                ],
              ),
            ),
            Transform.scale(scale: scale, child: child),
          ],
        );
      },
      child: const Icon(
        Icons.stop,
        color: Colors.redAccent,
        size: _kShutterStopIconSize,
      ),
    );
  }

  Widget _buildLockTrail() {
    final progress = _lockDragProgress.clamp(0.0, 1.0);
    return Align(
      alignment: Alignment.centerRight,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 70),
        curve: Curves.easeOut,
        width: 32 * progress,
        height: 6,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [
              Colors.redAccent,
              Color(0x99FF5252),
            ],
          ),
          borderRadius: BorderRadius.circular(4),
          boxShadow: progress > 0.05
              ? [
                  BoxShadow(
                    color: Colors.redAccent.withValues(alpha: 0.55),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
      ),
    );
  }

  Widget _buildLockHint() {
    const pillSize = 46.0;
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutBack,
      tween: Tween<double>(begin: 0.55, end: 1.0),
      builder: (context, entryScale, child) {
        return Transform.scale(scale: entryScale, child: child);
      },
      child: AnimatedBuilder(
      animation: _lockPulseController,
      builder: (context, _) {
        final pulse = _lockPulseController.value;
        final hot = _lockReadyToEngage;
        final progress = _lockDragProgress.clamp(0.0, 1.0);
        final basePulseScale =
            1.0 + (hot ? 0.0 : 0.10 * math.sin(pulse * 2 * math.pi));
        return SizedBox(
          width: 96,
          height: pillSize + 24,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // Chevron hints drifting leftward — hides as user drags in.
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Opacity(
                  opacity: (1.0 - progress).clamp(0.0, 1.0) * 0.85,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(3, (i) {
                      final phase = (pulse + i * 0.18) % 1.0;
                      final fade = (math.sin(phase * math.pi)).clamp(0.0, 1.0);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: Opacity(
                          opacity: 0.25 + 0.6 * fade,
                          child: Transform.translate(
                            offset: Offset(-6 * phase, 0),
                            child: const Icon(
                              Icons.chevron_left,
                              color: Colors.white,
                              size: 12,
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
              // Pulsing halo behind pill.
              Transform.scale(
                scale: hot ? 1.18 : basePulseScale,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: pillSize + 10,
                  height: pillSize + 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (hot
                            ? Colors.redAccent
                            : Colors.white)
                        .withValues(alpha: hot ? 0.30 : 0.12),
                  ),
                ),
              ),
              // Pill body.
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: pillSize,
                height: pillSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hot
                      ? Colors.redAccent.withValues(alpha: 0.95)
                      : Colors.black.withValues(alpha: 0.62),
                  border: Border.all(
                    color: Colors.white
                        .withValues(alpha: hot ? 0.98 : 0.72),
                    width: 1.6,
                  ),
                  boxShadow: hot
                      ? [
                          BoxShadow(
                            color: Colors.redAccent.withValues(alpha: 0.55),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: anim,
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: Icon(
                    hot
                        ? Icons.lock
                        : Icons.lock_outline,
                    key: ValueKey<bool>(hot),
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
    );
  }

  /// Discrete zoom presets (0.5x / 1x / 2x), shown only when the engine reports
  /// a meaningful range that includes them. Falls back to hidden otherwise.
  Widget _buildZoomPresetRow() {
    final span = _zoomMax - _zoomMin;
    if (span < 0.5) return const SizedBox.shrink();
    final candidates = <double>[];
    if (_zoomMin <= 0.5 + 1e-3) candidates.add(0.5);
    candidates.add(1.0);
    if (_zoomMax >= 2.0 - 1e-3) candidates.add(2.0);
    final shown = candidates
        .where((v) => v >= _zoomMin - 1e-3 && v <= _zoomMax + 1e-3)
        .toList();
    if (shown.length < 2) return const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final v in shown) ...[
              _zoomPresetChip(v),
              const SizedBox(width: 2),
            ],
          ],
        ),
      ),
    );
  }

  Widget _zoomPresetChip(double value) {
    final selected = (_zoomLevel - value).abs() < 0.06;
    final labelStr = value == value.roundToDouble()
        ? '${value.toStringAsFixed(0)}×'
        : '${value.toStringAsFixed(1)}×';
    return Semantics(
      button: true,
      label: 'Zoom $labelStr',
      selected: selected,
      child: InkResponse(
        onTap: () => unawaited(_setZoomPreset(value)),
        radius: 28,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected
                ? Colors.white.withValues(alpha: 0.92)
                : Colors.transparent,
          ),
          child: Text(
            labelStr,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1,
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
    String? semanticLabel,
  }) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticLabel,
      child: Material(
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
            child: Icon(
              icon,
              color: onPressed == null
                  ? Colors.white.withValues(alpha: 0.35)
                  : Colors.white,
              size: _kCornerIconSize,
            ),
          ),
        ),
      ),
    );
  }

  /// Vertical exposure slider (-2..+2 EV). Drag up = brighter. Bias label
  /// floats next to the thumb; tap the sun icon to reset to 0.
  Widget _buildExposureSlider() {
    return Semantics(
      label: 'Exposure ${_exposureBias.toStringAsFixed(1)} EV',
      slider: true,
      child: SizedBox(
        width: 36,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => unawaited(_onExposureBiasChanged(0)),
              child: const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Icon(
                  Icons.wb_sunny,
                  color: Color(0xFFFFD96A),
                  size: 18,
                ),
              ),
            ),
            Expanded(
              child: RotatedBox(
                quarterTurns: -1,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbColor: const Color(0xFFFFD96A),
                    activeTrackColor: const Color(0xFFFFD96A),
                    inactiveTrackColor: Colors.white24,
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    min: _kExposureMin,
                    max: _kExposureMax,
                    value: _exposureBias,
                    onChanged: (v) => unawaited(_onExposureBiasChanged(v)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 2,
                ),
                child: Text(
                  _exposureBias > 0
                      ? '+${_exposureBias.toStringAsFixed(1)}'
                      : _exposureBias.toStringAsFixed(1),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShutterCoachmark() {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0, end: 1),
      builder: (context, t, child) {
        return Opacity(opacity: t, child: child);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.16),
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.touch_app,
                color: Color(0xFF7DD3FC),
                size: 18,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  widget.videoOnly
                      ? 'Hold the shutter to record · slide left to lock'
                      : 'Tap shutter for photo · hold for video',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1.25,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
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
                Text(
                  _permCameraDenied && _permMicDenied
                      ? 'Camera and microphone permission are required to record.'
                      : _permCameraDenied
                          ? 'Camera permission is required to record.'
                          : 'Microphone permission is required to record sound.',
                  textAlign: TextAlign.center,
                ),
                if (_permPermanentlyDenied) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'You chose "Don\'t allow", so the system won\'t ask '
                    'again — enable it via Open settings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    await NativePermissions.openSettings();
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

    // Recorded clips / picked music are in-memory only — leaving this screen
    // throws them away, so back (button or gesture) must confirm first.
    return PopScope(
      canPop: !_hasUnsavedCapture,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmExitCapture());
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          if (eng == null && _busy && !kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS))
            const Positioned.fill(
              child: _MinisBootPreviewMount(),
            ),
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
              child: LayoutBuilder(
                builder: (ctx, c) {
                  final size = Size(c.maxWidth, c.maxHeight);
                  return GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onScaleStart: _onPreviewScaleStart,
                    onScaleUpdate: _onPreviewScaleUpdate,
                    onScaleEnd: _onPreviewScaleEnd,
                    onTapUp: (d) =>
                        unawaited(_onPreviewTapToFocus(d, size)),
                    onDoubleTap: (_busy || _recording || _countingDown)
                        ? null
                        : () => unawaited(_flip()),
                    onLongPressStart: (d) =>
                        _onPreviewLongPressToLock(d, size),
                    child: const SizedBox.expand(),
                  );
                },
              ),
            ),
          if (eng != null &&
              !_busy &&
              !_countingDown &&
              _aspectRatio != MinisAspectRatio.full)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _AspectFramingPainter(_aspectRatio.ratio!),
                ),
              ),
            ),
          if (eng != null && !_busy && !_countingDown && _gridVisible)
            const Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _RuleOfThirdsGridPainter()),
              ),
            ),
          if (eng != null && !_busy && _focusReticleAt != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _focusReticleController,
                  builder: (context, _) {
                    final t = _focusReticleController.value;
                    return CustomPaint(
                      painter: _FocusReticlePainter(
                        center: _focusReticleAt!,
                        progress: _aeAfLocked ? 0.0 : t,
                      ),
                    );
                  },
                ),
              ),
            ),
          if (eng != null && !_busy && _aeAfLocked && _focusReticleAt != null)
            Positioned(
              left: (_focusReticleAt!.dx - 40).clamp(8.0, 9999.0),
              top: (_focusReticleAt!.dy + 48).clamp(0.0, 9999.0),
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xCC1B2A3A),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF7DD3FC),
                      width: 1,
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Text(
                      'AE/AF LOCK',
                      style: TextStyle(
                        color: Color(0xFF7DD3FC),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (eng != null && !_busy && _exposureSliderVisible)
            Positioned(
              right: 14,
              top: topPad + 110,
              bottom: bottomPad + 220,
              child: _buildExposureSlider(),
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
            height: topPad + 56,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.45),
                      Colors.black.withValues(alpha: 0.0),
                    ],
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
                          // maybePop routes through PopScope so the
                          // discard-recording confirm can intercept.
                          unawaited(nav.maybePop());
                        }
                      },
                      icon: const PhosphorIcon(
                        PhosphorIconsRegular.caretLeft,
                        color: Colors.white,
                        size: _kAppBarIconSize,
                      ),
                    ),
                    const Spacer(),
                    if (_recording) ...[
                      _RecPill(
                        elapsedLabel: minisFormatClipDurationLabel(
                          _clipsTotalDurationMs + _liveClipElapsedMs,
                        ),
                        pulse: _recordPulseController,
                      ),
                      if (_micEnabled && _liveAudioLevels != null) ...[
                        const SizedBox(width: 8),
                        _AudioLevelMeter(levels: _liveAudioLevels!),
                      ],
                      if (!_micEnabled && _musicSegment == null) ...[
                        const SizedBox(width: 8),
                        const _MicMutedPill(),
                      ],
                    ],
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
                    icon: Icons.flip_camera_ios,
                    label: 'Flip',
                    onTap:
                        (_busy || _recording || _countingDown) ? null : _flip,
                  ),
                  if (_railExpanded) ...[
                    _railAction(
                      icon: Icons.music_note,
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
                      icon: Icons.speed,
                      label: _speedRailLabel,
                      onTap: (_busy || _recording || _countingDown)
                          ? null
                          : () => unawaited(_pickSpeed()),
                      onLongPress: (_busy || _recording || _countingDown)
                          ? null
                          : _cycleSpeed,
                    ),
                    if (!widget.videoOnly)
                      _railAction(
                        icon: Icons.timer,
                        label: _timerRailLabel,
                        onTap: (_busy || _recording || _countingDown)
                            ? null
                            : _cycleCountdownMode,
                      ),
                    _railAction(
                      icon: Icons.auto_awesome,
                      label: _activeFilter == null ? 'Filters' : 'Filter',
                      subtitle: _activeFilter?.name,
                      iconColor: _activeFilter != null
                          ? const Color(0xFF7DD3FC)
                          : null,
                      onTap: (_busy || _recording || _countingDown)
                          ? null
                          : _pickFilter,
                      onLongPress: (_busy ||
                              _recording ||
                              _countingDown ||
                              _activeFilter == null)
                          ? null
                          : () => unawaited(_setFilter(null)),
                    ),
                  ],
                  if (_caps.hdr10)
                    _railAction(
                      icon: _hdrEnabled
                          ? Icons.hdr_on
                          : Icons.hdr_off,
                      label: 'HDR',
                      iconColor:
                          _hdrEnabled ? const Color(0xFF7DD3FC) : null,
                      onTap: (_busy || _recording || _countingDown)
                          ? null
                          : _toggleHdr,
                    ),
                  if (_caps.manualWb)
                    _railAction(
                      icon: _wb.icon,
                      label: 'WB',
                      subtitle: _wb.label,
                      iconColor: _wb == MinisWhiteBalancePreset.auto
                          ? null
                          : const Color(0xFF7DD3FC),
                      onTap: (_busy || _recording || _countingDown)
                          ? null
                          : () => unawaited(_pickWhiteBalance()),
                    ),
                  if (_caps.slowMoFps.isNotEmpty)
                    _railAction(
                      icon: Icons.slow_motion_video,
                      label: 'Slo-mo',
                      subtitle: _slowMoFpsIdx < 0
                          ? 'off'
                          : '${_caps.slowMoFps[_slowMoFpsIdx]} fps',
                      iconColor: _slowMoFpsIdx >= 0
                          ? const Color(0xFF7DD3FC)
                          : null,
                      onTap: (_busy || _recording || _countingDown)
                          ? null
                          : _cycleSlowMo,
                    ),
                  _railAction(
                    icon: eng?.isTorchOn == true
                        ? Icons.flash_on
                        : Icons.flash_off,
                    label: 'Flash',
                    onTap: (_busy || _recording || _countingDown)
                        ? null
                        : _toggleTorch,
                  ),
                  _railAction(
                    icon: _gridVisible ? Icons.grid_on : Icons.grid_off,
                    label: 'Grid',
                    iconColor:
                        _gridVisible ? const Color(0xFF7DD3FC) : null,
                    onTap: (_busy || _countingDown)
                        ? null
                        : () {
                            setState(() => _gridVisible = !_gridVisible);
                            MinisCaptureSessionPrefs.instance.gridVisible =
                                _gridVisible;
                          },
                  ),
                  _railAction(
                    icon: Icons.aspect_ratio,
                    label: 'Frame',
                    subtitle: _aspectRatio.shortLabel,
                    iconColor: _aspectRatio == MinisAspectRatio.full
                        ? null
                        : const Color(0xFF7DD3FC),
                    onTap: (_busy || _recording || _countingDown)
                        ? null
                        : () => unawaited(_pickAspectRatio()),
                    onLongPress: (_busy || _recording || _countingDown)
                        ? null
                        : _cycleAspectRatio,
                  ),
                  _railAction(
                    icon: _micEnabled
                        ? Icons.mic
                        : Icons.mic_off,
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
                        TweenAnimationBuilder<double>(
                          key: ValueKey<int>(_countdownTick!),
                          duration: const Duration(seconds: 1),
                          curve: Curves.linear,
                          tween: Tween<double>(begin: 1.0, end: 0.0),
                          builder: (context, t, _) {
                            return SizedBox(
                              width: 168,
                              height: 168,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  CustomPaint(
                                    size: const Size(168, 168),
                                    painter: _CountdownRingPainter(
                                      progress: t,
                                    ),
                                  ),
                                  Text(
                                    '$_countdownTick',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 96,
                                      fontWeight: FontWeight.w200,
                                      height: 1,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Tap anywhere to cancel',
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
          if (eng != null && !_busy && _recording)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: bottomPad + 220,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (eng != null && !_busy && !_countingDown && !_recording)
            Positioned(
              left: 0,
              right: 0,
              bottom: bottomPad + 230,
              child: Center(child: _buildZoomPresetRow()),
            ),
          if (eng != null &&
              !_busy &&
              !_countingDown &&
              !_recording &&
              _videoClips.isEmpty &&
              !_shutterCoachmarkDismissed)
            Positioned(
              left: 24,
              right: 24,
              bottom: bottomPad + 190,
              child: IgnorePointer(
                child: Center(child: _buildShutterCoachmark()),
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
                          // Single-clip mode: show gallery when no clip recorded,
                          // show undo (delete) when a clip exists so user can re-capture.
                          child: _videoClips.isNotEmpty
                              ? _roundSecondaryButton(
                                  icon: Icons.undo,
                                  semanticLabel: 'Remove last clip',
                                  onPressed: (_busy ||
                                          _recording ||
                                          _countingDown)
                                      ? null
                                      : () => unawaited(
                                            _deleteLastVideoClip(),
                                          ),
                                )
                              : _roundSecondaryButton(
                                  icon: Icons.photo_library,
                                  semanticLabel:
                                      'Open gallery to import a clip',
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
                                     ? 'Clip recorded · tap ✓ to continue'
                                     : 'Hold to record video · or pick from gallery')
                                 : (_videoClips.isNotEmpty
                                     ? 'Clip ready · tap ✓ to continue'
                                     : 'Hold for video · tap for photo · or gallery'),
                             textAlign: TextAlign.center,
                             maxLines: 3,
                             overflow: TextOverflow.ellipsis,
                             style: TextStyle(
                               color: Colors.white.withValues(alpha: 0.65),
                               fontSize: 11,
                             ),
                           ),
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
                                  Semantics(
                                    button: true,
                                    label: _recording
                                        ? 'Stop recording'
                                        : (widget.videoOnly
                                            ? 'Hold to record video'
                                            : 'Hold for video, tap for photo'),
                                    hint: _recording
                                        ? 'Tap to finish'
                                        : 'Slide left to lock recording',
                                    child: Listener(
                                      onPointerDown: _onShutterPointerDown,
                                      onPointerMove: _onShutterPointerMove,
                                      onPointerUp: (_) =>
                                          _onShutterPointerUpOrCancel(),
                                      onPointerCancel: (_) =>
                                          _onShutterPointerUpOrCancel(
                                              cancelled: true),
                                      child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 220),
                                        curve: Curves.easeOutCubic,
                                        width: _kShutterInner,
                                        height: _kShutterInner,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: _recording
                                              ? Colors.redAccent
                                                  .withValues(alpha: 0.22)
                                              : Colors.white
                                                  .withValues(alpha: 0.08),
                                        ),
                                        alignment: Alignment.center,
                                        child: _recording
                                            ? _buildRecordingStopIcon()
                                            : null,
                                      ),
                                    ),
                                  ),
                                  if (_holdVideoArmed &&
                                      _recording &&
                                      !_recordingLocked)
                                    Positioned(
                                      left: -28,
                                      top: (_kShutterOuter - 8) / 2,
                                      width: 32,
                                      height: 8,
                                      child: IgnorePointer(
                                        child: _buildLockTrail(),
                                      ),
                                    ),
                                  if (_holdVideoArmed &&
                                      _recording &&
                                      !_recordingLocked)
                                    Positioned(
                                      left: -96,
                                      top: 0,
                                      bottom: 0,
                                      child: IgnorePointer(
                                        child: Center(
                                          child: _buildLockHint(),
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
                              if (_videoClips.isNotEmpty || _lastCapturePath != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    _videoClips.isNotEmpty
                                        ? 'Next'
                                        : (_lastCaptureIsVideo ? 'Video' : 'Photo'),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.7),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                            _roundSecondaryButton(
                              icon: Icons.check,
                              filled: _canConfirmClip,
                              semanticLabel: _canConfirmClip
                                  ? 'Continue with this clip'
                                  : 'Continue (disabled, no clip yet)',
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
