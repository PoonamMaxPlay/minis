import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:loopit_minis/src/independent/minis_preview_player.dart';

import 'package:loopit_minis/src/independent/minis_h264_repair_transcode.dart';
import 'package:loopit_minis/src/independent/minis_music_segment.dart';
import 'package:loopit_minis/src/independent/minis_reel_clip_trimmer_page.dart';
import 'package:loopit_minis/src/independent/minis_video_duration.dart';
import 'package:loopit_minis/src/independent/minis_video_file_ready.dart';
import 'package:loopit_minis/src/minis_user_message.dart';

/// Result of confirming [MinisVideoPreviewPage] — includes **durationMs** from
/// the same [VideoPlayerController] that rendered the preview (avoids bad
/// standalone file probes that often report ~1s for MP4s).
class MinisVideoPreviewResult {
  const MinisVideoPreviewResult({
    required this.path,
    required this.durationMs,
  });

  final String path;
  final int durationMs;
}

/// Full-screen video preview: play/pause, scrub timeline, optional **Trim**
/// (same [video_trimmer] flow as LoopIt), **Use** to return the current path,
/// **Close** to cancel (`null`).
class MinisVideoPreviewPage extends StatefulWidget {
  const MinisVideoPreviewPage({
    super.key,
    required this.videoPaths,
    this.title = 'Preview',
    this.confirmLabel = 'Use video',
    this.allowReelTrim = false,
    this.confirmOnClose = false,
    this.initialTotalDurationMs,
    this.musicSegment,
  });

  final List<String> videoPaths;
  final String title;
  final String confirmLabel;

  /// When true and [minisReelClipTrimmerPlatformSupported], shows **Trim** in
  /// the app bar (merged reel / long exports).
  final bool allowReelTrim;

  /// When true, closing without **Use** asks for confirmation (e.g. merged reel).
  final bool confirmOnClose;

  /// Known total duration for multi-clip previews (avoiding redundant probes).
  final int? initialTotalDurationMs;

  /// When non-null the preview mutes the original recorded clip audio so only
  /// the pure music track is heard (prevents the recorded mic vs. music
  /// double-audio when the user picked music during capture).
  final MinisMusicSegment? musicSegment;

  /// Pushes this page and returns path + duration when the user confirms.
  /// Waits for the file to exist (handles late flush after merge/export).
  static Future<MinisVideoPreviewResult?> open(
    BuildContext context,
    List<String> videoPaths, {
    String title = 'Preview',
    String confirmLabel = 'Use video',
    bool allowReelTrim = false,
    bool confirmOnClose = false,
    int? initialTotalDurationMs,
    MinisMusicSegment? musicSegment,
  }) async {
    if (videoPaths.isEmpty) return null;
    debugPrint(
      'MINIS_MULTICLIP: gallery:preview: MinisVideoPreviewPage.open start pathCount=${videoPaths.length}',
    );
    final ready = await waitUntilMinisVideoFileReady(videoPaths.first);
    debugPrint(
      'MINIS_MULTICLIP: gallery:preview: MinisVideoPreviewPage.open after wait ready=$ready '
      'contextMounted=${context.mounted}',
    );
    if (!ready || !context.mounted) {
      return null;
    }
    debugPrint(
        'MINIS_MULTICLIP: gallery:preview: MinisVideoPreviewPage.open pushing route');
    return Navigator.of(context, rootNavigator: true)
        .push<MinisVideoPreviewResult?>(
      MaterialPageRoute<MinisVideoPreviewResult?>(
        fullscreenDialog: true,
        builder: (_) => MinisVideoPreviewPage(
          videoPaths: videoPaths,
          title: title,
          confirmLabel: confirmLabel,
          allowReelTrim: allowReelTrim,
          confirmOnClose: confirmOnClose,
          initialTotalDurationMs: initialTotalDurationMs,
          musicSegment: musicSegment,
        ),
      ),
    );
  }

  @override
  State<MinisVideoPreviewPage> createState() => _MinisVideoPreviewPageState();
}

class _MinisVideoPreviewPageState extends State<MinisVideoPreviewPage> {
  late List<String> _paths;
  int _currentIndex = 0;
  late String _path;
  VideoPlayerController? _controller;
  MinisPreviewPlayerController? _nativeController;
  bool get _isMultiClip => _paths.length > 1;

  bool get _isReady => _isMultiClip ? (_nativeController?.isInitialized == true) : (_controller?.value.isInitialized == true);
  bool get _isPlaying => _isMultiClip ? (_nativeController?.isPlaying == true) : (_controller?.value.isPlaying == true);
  Duration get _currentPos => _isMultiClip ? (_nativeController?.position ?? Duration.zero) : (_controller?.value.position ?? Duration.zero);
  int get _currentDurMs => _isMultiClip ? (_nativeController?.duration.inMilliseconds ?? 0) : (_controller?.value.duration.inMilliseconds ?? 0);
  int get _totalDurMs {
    final p = _probedDurationMs ?? 0;
    final c = _currentDurMs;
    if (_isMultiClip) {
      // For multi-clip, we prefer the probed/initial total duration because
      // native players often report per-clip duration even in a sequence.
      return math.max(p, c);
    }
    // Single clip: video_player duration can be flaky (e.g. 1s). 
    // If we have a probe that is longer, use that.
    return math.max(c, p);
  }

  double get _ar {
    double ratio = 1.0;
    if (_isMultiClip) {
      final w = _nativeController?.videoSize?.width ?? 0;
      final h = _nativeController?.videoSize?.height ?? 0;
      if (w > 0 && h > 0) ratio = w / h;
    } else {
      final val = _controller?.value;
      if (val != null) {
        final w = val.size.width;
        final h = val.size.height;
        if (w > 0 && h > 0) ratio = w / h;
      }
    }
    if (ratio.isNaN || ratio.isInfinite || ratio <= 0) return 1.0;
    return ratio;
  }

  bool _isPathImage(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.jpg' || ext == '.jpeg' || ext == '.png' || ext == '.webp';
  }

  /// When set, preview reads this file; delete on dispose (not the handoff [_path]).
  String? _tempDecodePath;

  /// User-facing error only (never raw platform dumps).
  String? _playbackErrorText;
  bool _scrubbing = false;
  bool _confirmBusy = false;
  bool _isSwitchingVideo = false;
  int? _probedDurationMs;

  @override
  void initState() {
    super.initState();
    _paths = widget.videoPaths;
    _currentIndex = 0;
    _path = _paths[_currentIndex];

    _probedDurationMs = widget.initialTotalDurationMs;

    if (_isMultiClip && _probedDurationMs == null) {
      unawaited(_probeAllClipsDuration());
    } else if (_probedDurationMs == null) {
      // Asynchronously probe duration in case VideoPlayer fails to read it.
      minisFinalizeClipDurationMs(1, _path, fromGalleryFile: true).then((ms) {
        if (mounted) setState(() => _probedDurationMs = ms);
      });
    }

    if (_isMultiClip) {
      // Do NOT pass mute even when musicSegment != null: the merged preview
      // file has the pure music baked in (clip audio dropped at merge time).
      // Muting the native player would silence the music too.
      _nativeController = MinisPreviewPlayerController(_paths);
      _nativeController!.addListener(() {
        if (mounted) setState(() {});
      });
      // Start fake player initialization
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Wait briefly for native creation
      });
    } else {
      unawaited(_initPlaybackAsync());
    }
  }

  Future<void> _probeAllClipsDuration() async {
    final futures = _paths.map((p) => minisResolveVideoDurationMs(p));
    final results = await Future.wait(futures);
    final total = results.fold<int>(0, (sum, ms) => sum + ms);
    if (mounted) {
      setState(() => _probedDurationMs = total);
    }
  }

  Future<void> _initPlaybackAsync() async {
    _isSwitchingVideo = true;
    _probedDurationMs = null;
    if (_tempDecodePath != null) {
      try {
        await File(_tempDecodePath!).delete();
      } catch (_) {}
      _tempDecodePath = null;
    }
    
    // For single clip, if we cleared probedDuration, re-start a best-effort probe
    // in case the controller fails to read it later.
    if (!_isMultiClip) {
      minisFinalizeClipDurationMs(1, _path, fromGalleryFile: true).then((ms) {
        if (mounted && _path == widget.videoPaths[_currentIndex]) {
          setState(() => _probedDurationMs = ms);
        }
      });
    }

    await _bindAndPlay(_path, allowTempFallback: true);
    if (mounted) {
      setState(() => _isSwitchingVideo = false);
    }
  }

  /// Binds [VideoPlayerController] to [filePath]. On failure, copies [filePath] to
  /// app temp (when allowed), then re-encodes to H.264/720p — ExoPlayer often
  /// cannot open picker/merge/HEVC paths. On a successful re-encode init,
  /// [setPathToThisFileOnInit] updates [_path] so **Use** hands off a compatible
  /// file (smaller, upload-friendly, same path family as LoopIt reel).
  Future<void> _bindAndPlay(
    String filePath, {
    required bool allowTempFallback,
    bool allowH264Repair = true,
    bool setPathToThisFileOnInit = false,
  }) async {
    _controller?.removeListener(_onVideoTick);
    await _controller?.pause();
    await _controller?.dispose();
    _controller = null;
    _playbackErrorText = null;

    final c = VideoPlayerController.file(
      File(filePath),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = c;
    c.addListener(_onVideoTick);
    try {
      await c.initialize();
      if (_paths.length == 1) {
        await c.setLooping(true);
      }
      await c.play();
      if (mounted) {
        if (setPathToThisFileOnInit) {
          _path = filePath;
        }
        setState(() {});
      }
    } catch (e) {
      await _controller?.pause();
      await _controller?.dispose();
      _controller = null;
      if (!mounted) return;
      if (allowTempFallback && filePath == _path) {
        final alt = await minisCopyVideoToTempForPlayback(_path);
        if (alt != null && mounted) {
          _tempDecodePath = alt;
          await _bindAndPlay(
            alt,
            allowTempFallback: false,
            allowH264Repair: allowH264Repair,
            setPathToThisFileOnInit: false,
          );
          return;
        }
      }
      if (_tempDecodePath != null && filePath == _tempDecodePath) {
        try {
          await File(_tempDecodePath!).delete();
        } catch (_) {}
        _tempDecodePath = null;
      }
      if (allowH264Repair) {
        if (mounted) {
          // decoder not ready: show the loading lane while we re-encode
          setState(() {});
        }
        final repaired = await minisTranscodeToH264ForDevicePlayback(_path);
        if (repaired != null && mounted) {
          await _bindAndPlay(
            repaired,
            allowTempFallback: false,
            allowH264Repair: false,
            setPathToThisFileOnInit: true,
          );
          return;
        }
      }
      if (filePath != _path && !widget.videoPaths.contains(filePath)) {
        try {
          await File(filePath).delete();
        } catch (_) {}
      }
      setState(() {
        _playbackErrorText = minisUserFriendlyException(e, context: 'playback');
      });
    }
  }

  void _initController() {
    if (_isMultiClip) {
      _nativeController?.dispose();
      // Do NOT pass mute even when musicSegment != null: the merged preview
      // file has the pure music baked in (clip audio dropped at merge time).
      // Muting the native player would silence the music too.
      _nativeController = MinisPreviewPlayerController(_paths);
      _nativeController!.addListener(() {
        if (mounted) setState(() {});
      });
      if (mounted) setState(() {});
    } else {
      unawaited(_initPlaybackAsync());
    }
  }

  void _onVideoTick() {
    if (!mounted) return;
    final c = _controller;
    // Ignore decoder noise before init completes; avoids flaky "playback" errors.
    if (_isReady && c!.value.hasError && _playbackErrorText == null) {
      final desc = c.value.errorDescription;
      if (desc != null && desc.isNotEmpty) {
        _playbackErrorText =
            minisUserFriendlyException(desc, context: 'playback');
      }
    }
    if (_scrubbing) return;

    if (_isReady && !_isSwitchingVideo) {}

    setState(() {});
  }

  Future<void> _openTrim() async {
    if (!minisReelClipTrimmerPlatformSupported()) return;
    if (_isMultiClip) {
      _nativeController?.pause();
    } else {
      _controller?.pause();
    }
    setState(() {});
    final trimmed = await MinisReelClipTrimmerPage.open(context, File(_path));
    if (!mounted || trimmed == null || trimmed.path.isEmpty) return;
    setState(() => _path = trimmed.path);
    _initController();
  }

  Future<void> _onClosePressed() async {
    final nav = Navigator.of(context, rootNavigator: true);
    if (!widget.confirmOnClose) {
      nav.pop<MinisVideoPreviewResult?>();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this video?'),
        content: const Text(
          'You will go back to the camera without using this video.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      nav.pop<MinisVideoPreviewResult?>();
    }
  }

  void _maybeDeleteOrphanTrimmedFile(Object? result) {
    if (result != null) return;
    if (!widget.videoPaths.contains(_path)) {
      unawaited(
        (() async {
          try {
            await File(_path).delete();
          } catch (_) {}
        })(),
      );
    }
  }

  Future<void> _onConfirm() async {
    final c = _controller;
    if (!_isReady || _confirmBusy) return;
    setState(() => _confirmBusy = true);
    final pathForResult = _path;
    try {
      if (!_isMultiClip && c != null) {
        await minisWaitForVideoControllerDuration(c);
      }
      if (!mounted) return;
      
      // Prefer _totalDurMs which includes the background probe result.
      var ms = _totalDurMs;
      
      // Nudge duration on some encoders (stuck at default 1s until after seek).
      if (!_isMultiClip && ms > 0 && ms < 2500 && c != null) {
        try {
          final d = c.value.duration;
          await c.seekTo(
              Duration(milliseconds: math.max(0, d.inMilliseconds - 200)));
          await Future<void>.delayed(const Duration(milliseconds: 120));
          if (mounted) {
            ms = math.max(ms, _totalDurMs);
          }
        } catch (_) {}
      }
      
      // Release preview decoder before any standalone probe
      final oldC = _controller;
      _controller?.removeListener(_onVideoTick);
      _nativeController?.dispose();
      setState(() {
        _controller = null;
        _nativeController = null;
      });
      await oldC?.pause();
      await oldC?.dispose();
      if (!mounted) return;

      try {
        if (ms >= 3000) {
          // If we have a solid duration from preview, metadata check is just a safety.
          final metaMs =
              await minisResolveVideoDurationMsMetadataOnly(pathForResult);
          ms = math.max(ms, metaMs);
        } else if (ms >= 900) {
          final metaMs =
              await minisResolveVideoDurationMsMetadataOnly(pathForResult);
          ms = math.max(ms, metaMs);
          if (ms < 2800) {
            final fileMs = await minisResolveVideoDurationMs(pathForResult);
            ms = math.max(ms, fileMs);
          }
        } else {
          var fileMs =
              await minisResolveVideoDurationMsBestEffort(pathForResult);
          ms = math.max(ms, fileMs);
          if (ms < 2000) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            fileMs = await minisResolveVideoDurationMs(pathForResult);
            ms = math.max(ms, fileMs);
          }
        }
        if (ms <= 0) {
          ms = 1;
        }
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pop<MinisVideoPreviewResult>(
          MinisVideoPreviewResult(path: pathForResult, durationMs: ms),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              minisUserFriendlyException(e, context: 'duration'),
            ),
          ),
        );
        await _initPlaybackAsync();
      }
    } finally {
      if (mounted) setState(() => _confirmBusy = false);
    }
  }

  /// When preview cannot play, still confirm using file-based duration (no working controller).
  Future<void> _onConfirmWithoutPreview() async {
    if (_confirmBusy) return;
    setState(() => _confirmBusy = true);
    final pathForResult = _path;
    try {
      // Release any half-initialized decoder before duration probes run.
      final oldC = _controller;
      _controller?.removeListener(_onVideoTick);
      setState(() => _controller = null);
      await oldC?.pause();
      await oldC?.dispose();

      final ms = await minisFinalizeClipDurationMs(
        1,
        pathForResult,
        fromGalleryPreview: false,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop<MinisVideoPreviewResult>(
        MinisVideoPreviewResult(path: pathForResult, durationMs: ms),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            minisUserFriendlyException(e, context: 'duration'),
          ),
        ),
      );
      await _initPlaybackAsync();
    } finally {
      if (mounted) setState(() => _confirmBusy = false);
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.pause();
    _controller?.dispose();
    _nativeController?.dispose();
    if (_tempDecodePath != null) {
      try {
        File(_tempDecodePath!).deleteSync();
      } catch (_) {}
      _tempDecodePath = null;
    }
    super.dispose();
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final nc = _nativeController;
    final theme = Theme.of(context);
    final showTrim =
        widget.allowReelTrim && minisReelClipTrimmerPlatformSupported();

    return PopScope<MinisVideoPreviewResult?>(
      canPop: !widget.confirmOnClose,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          _maybeDeleteOrphanTrimmedFile(result);
          return;
        }
        if (widget.confirmOnClose && mounted) {
          await _onClosePressed();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
          title: Text(
            widget.title,
            overflow: TextOverflow.ellipsis,
          ),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => unawaited(_onClosePressed()),
          ),
          actions: [
            if (showTrim)
              IconButton(
                tooltip: 'Trim',
                icon: const Icon(Icons.content_cut),
                color: const Color(0xFF5AC8FA),
                onPressed: _playbackErrorText != null || !_isReady
                    ? null
                    : _openTrim,
              ),
            TextButton(
              onPressed: _confirmBusy
                  ? null
                  : _playbackErrorText != null
                      ? () => unawaited(_onConfirmWithoutPreview())
                      : (_isReady)
                          ? () => unawaited(_onConfirm())
                          : null,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: _confirmBusy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      widget.confirmLabel,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ],
        ),
        body: Stack(
          children: [
            SafeArea(
              child: _playbackErrorText != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.videocam_off_outlined,
                              size: 48,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              _playbackErrorText!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                height: 1.45,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 24),
                            OutlinedButton.icon(
                              onPressed: () {
                                setState(() => _playbackErrorText = null);
                                _initController();
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.45),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 12,
                                ),
                              ),
                              icon: const Icon(Icons.refresh, size: 20),
                              label: const Text('Try again'),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _confirmBusy
                                  ? null
                                  : () => unawaited(_onConfirmWithoutPreview()),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                              ),
                              child: const Text('Continue without preview'),
                            ),
                            Text(
                              'Uses the file length on disk. You will not see playback here.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white54,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : (!_isReady && !_isMultiClip)
                      ? const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        )
                      : Column(
                          children: [
                            Expanded(
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final localAr = _ar;
                                      var w = constraints.maxWidth;
                                      var h = w / localAr;
                                      if (h > constraints.maxHeight) {
                                        h = constraints.maxHeight;
                                        w = h * localAr;
                                      }
                                      return SizedBox(
                                        width: w,
                                        height: h,
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            Positioned.fill(
                                              child: _isMultiClip
                                                  ? (nc != null
                                                      ? MinisPreviewPlayerWidget(
                                                          controller: nc)
                                                      : const ColoredBox(
                                                          color: Colors.black))
                                                  : (c != null
                                                      ? VideoPlayer(c)
                                                      : const ColoredBox(
                                                          color: Colors.black)),
                                            ),
                                            if (!_isReady)
                                              const Center(
                                                child:
                                                    CircularProgressIndicator(
                                                        color: Colors.white),
                                              ),
                                            if (_isReady)
                                              Material(
                                                color: Colors.transparent,
                                                child: InkWell(
                                                  onTap: () {
                                                    if (_isPlaying) {
                                                      _isMultiClip
                                                          ? nc?.pause()
                                                          : c?.pause();
                                                    } else {
                                                      _isMultiClip
                                                          ? nc?.play()
                                                          : c?.play();
                                                    }
                                                    setState(() {});
                                                  },
                                                  customBorder:
                                                      const CircleBorder(),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(8),
                                                    child: Icon(
                                                      _isPlaying
                                                          ? Icons
                                                              .pause_circle_filled
                                                          : Icons
                                                              .play_circle_filled,
                                                      size: 72,
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.92),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
