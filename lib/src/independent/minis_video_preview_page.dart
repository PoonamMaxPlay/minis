import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'package:loopit_minis/src/independent/minis_reel_clip_trimmer_page.dart';
import 'package:loopit_minis/src/independent/minis_video_file_ready.dart';

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
  });

  final String videoPath;
  final String title;
  final String confirmLabel;

  /// When true and [minisReelClipTrimmerPlatformSupported], shows **Trim** in
  /// the app bar (merged reel / long exports).
  final bool allowReelTrim;

  /// Pushes this page and returns the active file path if the user confirms.
  /// Waits for the file to exist (handles late flush after merge/export).
  static Future<String?> open(
    BuildContext context,
    String videoPath, {
    String title = 'Preview',
    String confirmLabel = 'Use video',
    bool allowReelTrim = false,
  }) async {
    final ready = await waitUntilMinisVideoFileReady(videoPath);
    if (!ready || !context.mounted) {
      return null;
    }
    return Navigator.of(context).push<String?>(
      MaterialPageRoute<String?>(
        fullscreenDialog: true,
        builder: (_) => MinisVideoPreviewPage(
          videoPath: videoPath,
          title: title,
          confirmLabel: confirmLabel,
          allowReelTrim: allowReelTrim,
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
  Object? _initError;
  bool _scrubbing = false;

  @override
  void initState() {
    super.initState();
    _path = widget.videoPath;
    _initController();
  }

  void _initController() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    _controller = null;
    _initError = null;
    final c = VideoPlayerController.file(File(_path));
    _controller = c;
    c.addListener(_onVideoTick);
    c.initialize().then((_) {
      if (mounted) setState(() {});
    }).catchError((Object e) {
      if (mounted) setState(() => _initError = e);
    });
  }

  void _onVideoTick() {
    if (_scrubbing || !mounted) return;
    setState(() {});
  }

  Future<void> _openTrim() async {
    if (!minisReelClipTrimmerPlatformSupported()) return;
    final trimmed = await MinisReelClipTrimmerPage.open(context, File(_path));
    if (!mounted || trimmed == null || trimmed.path.isEmpty) return;
    setState(() => _path = trimmed.path);
    _initController();
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

  @override
  void dispose() {
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
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
    final showTrim = widget.allowReelTrim &&
        minisReelClipTrimmerPlatformSupported();

    return PopScope<String?>(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _maybeDeleteOrphanTrimmedFile(result);
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
            onPressed: () => Navigator.of(context).pop<String?>(),
          ),
          actions: [
            if (showTrim)
              IconButton(
                tooltip: 'Trim',
                icon: const Icon(Icons.content_cut),
                color: const Color(0xFF5AC8FA),
                onPressed:
                    _initError != null || c == null || !c.value.isInitialized
                        ? null
                        : _openTrim,
              ),
            TextButton(
              onPressed:
                  _initError != null || c == null || !c.value.isInitialized
                      ? null
                      : () => Navigator.of(context).pop<String?>(_path),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(
                widget.confirmLabel,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: _initError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not play this file.\n$_initError',
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white70, height: 1.4),
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
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
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
                                            customBorder: const CircleBorder(),
                                            child: Padding(
                                              padding: const EdgeInsets.all(8),
                                              child: Icon(
                                                c.value.isPlaying
                                                    ? Icons.pause_circle_filled
                                                    : Icons.play_circle_filled,
                                                size: 72,
                                                color: Colors.white
                                                    .withValues(alpha: 0.92),
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
                                  overlayShape: const RoundSliderOverlayShape(
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
      ),
    );
  }
}
