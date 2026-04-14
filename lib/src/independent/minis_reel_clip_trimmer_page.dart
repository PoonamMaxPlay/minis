import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
/// Returns [MinisReelTrimResult] on save, or `null` on cancel.
class MinisReelClipTrimmerPage extends StatefulWidget {
  const MinisReelClipTrimmerPage({super.key, required this.videoFile});

  final File videoFile;

  static Future<MinisReelTrimResult?> open(
    BuildContext context,
    File videoFile,
  ) {
    return Navigator.of(context).push<MinisReelTrimResult>(
      MaterialPageRoute<MinisReelTrimResult>(
        builder: (_) => MinisReelClipTrimmerPage(videoFile: videoFile),
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
  bool _isPlaying = false;
  bool _loadFailed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadVideo();
  }

  Future<void> _loadVideo() async {
    try {
      await _trimmer.loadVideo(videoFile: widget.videoFile);
      if (!mounted) {
        return;
      }
      final total =
          _trimmer.videoPlayerController?.value.duration.inMilliseconds ?? 0;
      setState(() {
        _endMs = total > 0 ? total.toDouble() : 0;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadFailed = true);
      }
    }
  }

  @override
  void dispose() {
    _trimmer.videoPlayerController?.dispose();
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
            Navigator.of(context).pop(
              MinisReelTrimResult(path: outputPath, durationMs: spanMs),
            );
            return;
          }
          setState(() => _saving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not save trim.')),
          );
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Trim failed: $e')),
        );
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

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Trim clip'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
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
                child: VideoViewer(trimmer: _trimmer),
              ),
              TrimViewer(
                trimmer: _trimmer,
                viewerHeight: 56,
                viewerWidth: width,
                maxVideoLength: const Duration(milliseconds: 0),
                type: ViewerType.auto,
                onChangeStart: (v) => _startMs = v,
                onChangeEnd: (v) => _endMs = v,
                onChangePlaybackState: (playing) {
                  if (mounted) {
                    setState(() => _isPlaying = playing);
                  }
                },
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
