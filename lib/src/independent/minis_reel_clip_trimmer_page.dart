import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopit_minis/src/independent/minis_video_duration.dart';
import 'package:loopit_minis/src/native_video_trim_user_message.dart';
import 'package:loopit_minis/src/session_and_toast.dart';
import 'package:path/path.dart' as p;
import 'package:video_trimmer/video_trimmer.dart';

/// Android / iOS only - same stack as LoopIt [ReelClipTrimmerPage].
bool minisReelClipTrimmerPlatformSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

/// Path and duration from [MinisReelClipTrimmerPage] save.
///
/// [durationMs] is the trim window (end − start), not file metadata — some
/// encoders leave container duration stale; UI and reel caps should use this.
class MinisReelTrimResult {
  const MinisReelTrimResult({
    required this.path,
    required this.durationMs,
  });

  final String path;
  final int durationMs;
}

/// Full-screen trimmer for one video file (package:video_trimmer).
///
/// [maxOutputDuration] caps how long the trimmed segment may be (e.g. remaining
/// reel budget when appending a long gallery clip). Defaults to 30s when null.
///
/// Returns [MinisReelTrimResult] on save, or `null` on cancel.
class MinisReelClipTrimmerPage extends StatefulWidget {
  const MinisReelClipTrimmerPage({
    super.key,
    required this.videoFile,
    this.maxOutputDuration,
  });

  final File videoFile;

  /// Maximum duration of the exported trim. Clamped per-video to source length.
  final Duration? maxOutputDuration;

  static Future<MinisReelTrimResult?> open(
    BuildContext context,
    File videoFile, {
    Duration? maxOutputDuration,
  }) {
    return Navigator.of(context, rootNavigator: true).push<MinisReelTrimResult>(
      MaterialPageRoute<MinisReelTrimResult>(
        builder: (_) => MinisReelClipTrimmerPage(
          videoFile: videoFile,
          maxOutputDuration: maxOutputDuration,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<MinisReelClipTrimmerPage> createState() =>
      _MinisReelClipTrimmerPageState();
}

class _MinisReelClipTrimmerPageState extends State<MinisReelClipTrimmerPage> {
  final Trimmer _trimmer = Trimmer();

  double _startMs = 0;
  double _endMs = 0;
  /// Passed to [TrimViewer.maxVideoLength] (min of cap, source duration).
  Duration _viewerMaxOut = const Duration(seconds: 30);
  bool _isPlaying = false;
  bool _loadFailed = false;
  /// False until duration is known and trim handles are safe to use.
  bool _videoLoaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Match package example: start [Trimmer.loadVideo] without awaiting in a way
    // that blocks the first frame, so [TrimViewer] mounts and subscribes to
    // [TrimmerEvent.initialized] before the async initialize() completes.
    unawaited(_loadVideo());
  }

  Future<void> _loadVideo() async {
    try {
      await _trimmer.loadVideo(videoFile: widget.videoFile);
      if (!mounted) {
        return;
      }
      final ctrl = _trimmer.videoPlayerController;
      if (ctrl == null) {
        setState(() => _loadFailed = true);
        return;
      }
      await minisWaitForVideoControllerDuration(ctrl);
      if (!mounted) return;
      final total = ctrl.value.duration.inMilliseconds;
      if (total <= 0) {
        setState(() => _loadFailed = true);
        return;
      }
      final capReq = widget.maxOutputDuration?.inMilliseconds ?? 30000;
      final maxSegMs = math.min(capReq, total);
      setState(() {
        _viewerMaxOut = Duration(milliseconds: math.max(1, maxSegMs));
        _startMs = 0;
        _endMs = math.min(total.toDouble(), maxSegMs.toDouble());
        _videoLoaded = true;
      });
    } catch (e, st) {
      logVideoTrimDiagnostic(
        e,
        stackTrace: st,
        context: 'MinisReelClipTrimmerPage._loadVideo',
        extra: {
          'sourceFile': p.basename(widget.videoFile.path),
          'phase': 'loadVideo',
        },
      );
      if (mounted) {
        setState(() => _loadFailed = true);
      }
    }
  }

  @override
  void dispose() {
    // Do not call [VideoPlayerController.dispose] here: [video_trimmer]'s
    // [FixedTrimViewer]/[ScrollableTrimViewer] already dispose the shared
    // [Trimmer.videoPlayerController] on pop; double-dispose causes
    // "used after being disposed" in Crashlytics.
    _trimmer.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_endMs <= _startMs || _saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _trimmer.saveTrimmedVideo(
        startValue: _startMs,
        endValue: _endMs,
        storageDir: StorageDir.temporaryDirectory,
        videoFolderName: 'MinisReelTrim',
        onSave: (outputPath) {
          if (!mounted) {
            return;
          }
          if (outputPath != null && outputPath.isNotEmpty) {
            final spanMs =
                (_endMs - _startMs).round().clamp(1, 24 * 60 * 60 * 1000);
            Navigator.of(context, rootNavigator: true).pop(
              MinisReelTrimResult(path: outputPath, durationMs: spanMs),
            );
            return;
          }
          logVideoTrimMissingOutputDiagnostic(
            context: 'MinisReelClipTrimmerPage.saveTrimmedVideo',
            extra: {
              'sourceFile': p.basename(widget.videoFile.path),
              'startMs': _startMs,
              'endMs': _endMs,
              'spanMs': _endMs - _startMs,
            },
          );
          setState(() => _saving = false);
          showMinisToast(context, messageForVideoTrimMissingOutput());
        },
      );
    } catch (e, st) {
      logVideoTrimDiagnostic(
        e,
        stackTrace: st,
        context: 'MinisReelClipTrimmerPage._save',
        extra: {
          'sourceFile': p.basename(widget.videoFile.path),
          'startMs': _startMs,
          'endMs': _endMs,
        },
      );
      if (mounted) {
        setState(() => _saving = false);
        showMinisToast(context, messageForVideoTrimFailure(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadFailed) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Trim clip'),
        ),
        body: const Center(
          child: Text(
            'Could not load this clip.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final accent = Theme.of(context).colorScheme.primary;
    final capSec = widget.maxOutputDuration?.inSeconds;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          capSec != null ? 'Trim (up to ${capSec}s for this reel)' : 'Trim clip',
        ),
        actions: [
          TextButton(
            onPressed: (_saving || !_videoLoaded) ? null : _save,
            child: Text(
              'Save',
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    VideoViewer(trimmer: _trimmer),
                    if (!_videoLoaded)
                      const ColoredBox(
                        color: Color(0xCC000000),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(color: Colors.white),
                              SizedBox(height: 12),
                              Text(
                                'Loading…',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Non-zero max length matches the package example; [Duration.zero]
              // forces a code path where the scroll vs fixed picker can misbehave on
              // some devices. Use a typical segment cap so [ViewerType.auto] can
              // choose [ScrollableTrimViewer] for long clips (better track UX).
              ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: width,
                  maxWidth: width,
                  minHeight: 100,
                ),
                child: TrimViewer(
                  trimmer: _trimmer,
                  viewerHeight: 56,
                  viewerWidth: width,
                  maxVideoLength: _viewerMaxOut,
                  type: ViewerType.auto,
                  durationStyle: DurationStyle.FORMAT_MM_SS,
                  onChangeStart: (v) => _startMs = v,
                  onChangeEnd: (v) => _endMs = v,
                  onChangePlaybackState: (playing) {
                    if (mounted) {
                      setState(() => _isPlaying = playing);
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: IconButton(
                  iconSize: 64,
                  color: Colors.white,
                  onPressed: () async {
                    final playing = await _trimmer.videoPlaybackControl(
                      startValue: _startMs,
                      endValue: _endMs,
                    );
                    if (mounted) {
                      setState(() => _isPlaying = playing);
                    }
                  },
                  icon: Icon(
                    _isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
          if (_saving)
            const ColoredBox(
              color: Color(0x88000000),
              child: Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}
