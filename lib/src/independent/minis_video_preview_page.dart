import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

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
    required this.videoPath,
    this.title = 'Preview',
    this.confirmLabel = 'Use video',
    this.allowReelTrim = false,
    this.confirmOnClose = false,
  });

  final String videoPath;
  final String title;
  final String confirmLabel;

  /// When true and [minisReelClipTrimmerPlatformSupported], shows **Trim** in
  /// the app bar (merged reel / long exports).
  final bool allowReelTrim;

  /// When true, closing without **Use** asks for confirmation (e.g. merged reel).
  final bool confirmOnClose;

  /// Pushes this page and returns path + duration when the user confirms.
  /// Waits for the file to exist (handles late flush after merge/export).
  static Future<MinisVideoPreviewResult?> open(
    BuildContext context,
    String videoPath, {
    String title = 'Preview',
    String confirmLabel = 'Use video',
    bool allowReelTrim = false,
    bool confirmOnClose = false,
  }) async {
    final ready = await waitUntilMinisVideoFileReady(videoPath);
    if (!ready || !context.mounted) {
      return null;
    }
    return Navigator.of(context, rootNavigator: true)
        .push<MinisVideoPreviewResult?>(
      MaterialPageRoute<MinisVideoPreviewResult?>(
        fullscreenDialog: true,
        builder: (_) => MinisVideoPreviewPage(
          videoPath: videoPath,
          title: title,
          confirmLabel: confirmLabel,
          allowReelTrim: allowReelTrim,
          confirmOnClose: confirmOnClose,
        ),
      ),
    );
  }

  @override
  State<MinisVideoPreviewPage> createState() => _MinisVideoPreviewPageState();
}

class _MinisVideoPreviewPageState extends State<MinisVideoPreviewPage> {
  late String _path;
  VideoPlayerController? _controller;

  /// When set, preview reads this file; delete on dispose (not the handoff [_path]).
  String? _tempDecodePath;

  /// User-facing error only (never raw platform dumps).
  String? _playbackErrorText;
  bool _scrubbing = false;
  bool _confirmBusy = false;

  @override
  void initState() {
    super.initState();
    _path = widget.videoPath;
    unawaited(_initPlaybackAsync());
  }

  Future<void> _initPlaybackAsync() async {
    if (_tempDecodePath != null) {
      try {
        await File(_tempDecodePath!).delete();
      } catch (_) {}
      _tempDecodePath = null;
    }
    await _bindAndPlay(_path, allowTempFallback: true);
  }

  /// Binds [VideoPlayerController] to [filePath]. On failure, copies [_path] to
  /// temp once — ExoPlayer often cannot open picker/merge paths but can open a temp copy.
  Future<void> _bindAndPlay(
    String filePath, {
    required bool allowTempFallback,
  }) async {
    _controller?.removeListener(_onVideoTick);
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
      if (mounted) setState(() {});
    } catch (e) {
      await _controller?.dispose();
      _controller = null;
      if (!mounted) return;
      if (allowTempFallback && filePath == _path) {
        final alt = await minisCopyVideoToTempForPlayback(_path);
        if (alt != null && mounted) {
          _tempDecodePath = alt;
          await _bindAndPlay(alt, allowTempFallback: false);
          return;
        }
      }
      if (_tempDecodePath != null && filePath == _tempDecodePath) {
        try {
          await File(_tempDecodePath!).delete();
        } catch (_) {}
        _tempDecodePath = null;
      }
      setState(() {
        _playbackErrorText =
            minisUserFriendlyException(e, context: 'playback');
      });
    }
  }

  void _initController() {
    unawaited(_initPlaybackAsync());
  }

  void _onVideoTick() {
    if (!mounted) return;
    final c = _controller;
    // Ignore decoder noise before init completes; avoids flaky "playback" errors.
    if (c != null &&
        c.value.isInitialized &&
        c.value.hasError &&
        _playbackErrorText == null) {
      final desc = c.value.errorDescription;
      if (desc != null && desc.isNotEmpty) {
        _playbackErrorText =
            minisUserFriendlyException(desc, context: 'playback');
      }
    }
    if (_scrubbing) return;
    setState(() {});
  }

  Future<void> _openTrim() async {
    if (!minisReelClipTrimmerPlatformSupported()) return;
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
    if (_path != widget.videoPath) {
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
    if (c == null || !c.value.isInitialized || _confirmBusy) return;
    setState(() => _confirmBusy = true);
    final pathForResult = _path;
    try {
      await minisWaitForVideoControllerDuration(c);
      if (!mounted) return;
      var ms = c.value.duration.inMilliseconds;
      // Nudge duration on some encoders (stuck at default 1s until after seek).
      if (ms > 0 && ms < 2000) {
        try {
          final d = c.value.duration;
          await c.seekTo(
              Duration(milliseconds: math.max(0, d.inMilliseconds - 200)));
          await Future<void>.delayed(const Duration(milliseconds: 120));
          if (mounted) {
            ms = math.max(ms, c.value.duration.inMilliseconds);
          }
        } catch (_) {}
      }
      // Release preview decoder before any standalone probe — mandatory on Android
      // when opening another player on the same path.
      _controller?.removeListener(_onVideoTick);
      await _controller?.dispose();
      _controller = null;
      if (!mounted) return;

      try {
        if (ms >= 2500) {
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
      _controller?.removeListener(_onVideoTick);
      await _controller?.dispose();
      _controller = null;

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
    _controller?.dispose();
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
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
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
                onPressed: _playbackErrorText != null ||
                        c == null ||
                        !c.value.isInitialized
                    ? null
                    : _openTrim,
              ),
            TextButton(
              onPressed: _confirmBusy
                  ? null
                  : _playbackErrorText != null
                      ? () => unawaited(_onConfirmWithoutPreview())
                      : (c != null && c.value.isInitialized)
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
                                  : () =>
                                      unawaited(_onConfirmWithoutPreview()),
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
                  : c == null || !c.value.isInitialized
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
                                      final ar = c.value.aspectRatio;
                                      var w = constraints.maxWidth;
                                      var h = w / ar;
                                      if (h > constraints.maxHeight) {
                                        h = constraints.maxHeight;
                                        w = h * ar;
                                      }
                                      return SizedBox(
                                        width: w,
                                        height: h,
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            Positioned.fill(
                                              child: VideoPlayer(c),
                                            ),
                                            Material(
                                              color: Colors.transparent,
                                              child: InkWell(
                                                onTap: () {
                                                  if (c.value.isPlaying) {
                                                    c.pause();
                                                  } else {
                                                    c.play();
                                                  }
                                                  setState(() {});
                                                },
                                                customBorder:
                                                    const CircleBorder(),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.all(8),
                                                  child: Icon(
                                                    c.value.isPlaying
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
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        _formatDuration(c.value.position),
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        _formatDuration(c.value.duration),
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 8,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                        overlayRadius: 16,
                                      ),
                                    ),
                                    child: Slider(
                                      value: c.value.duration.inMilliseconds > 0
                                          ? c.value.position.inMilliseconds
                                              .clamp(
                                                0,
                                                c.value.duration.inMilliseconds,
                                              )
                                              .toDouble()
                                          : 0,
                                      max: c.value.duration.inMilliseconds > 0
                                          ? c.value.duration.inMilliseconds
                                              .toDouble()
                                          : 1,
                                      onChangeStart: (_) {
                                        _scrubbing = true;
                                      },
                                      onChanged: (v) {
                                        c.seekTo(
                                          Duration(milliseconds: v.round()),
                                        );
                                        setState(() {});
                                      },
                                      onChangeEnd: (_) {
                                        _scrubbing = false;
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
            ),
            if (_confirmBusy)
              Positioned.fill(
                child: AbsorbPointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.45),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 40,
                            height: 40,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Preparing reel…',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
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
