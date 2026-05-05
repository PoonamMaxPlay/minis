import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:loopit_minis/src/independent/minis_h264_repair_transcode.dart';
import 'package:loopit_minis/src/independent/minis_video_duration.dart';
import 'package:loopit_minis/src/session_and_toast.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:retrytech_plugin/retrytech_plugin.dart';
import 'package:video_player/video_player.dart';

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
  VideoPlayerController? _controller;

  late File _activeVideoFile;
  String? _repairTempPath;
  bool _h264RepairTried = false;
  bool _reencodingForDevice = false;

  double _startMs = 0;
  double _endMs = 0;
  double _totalMs = 0;
  bool _isPlaying = false;
  bool _loadFailed = false;
  bool _videoLoaded = false;
  bool _saving = false;
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    _activeVideoFile = widget.videoFile;
    unawaited(_loadVideo());
  }

  Future<void> _failLoadOrReencode() async {
    if (!_h264RepairTried) {
      _h264RepairTried = true;
      if (mounted) setState(() => _reencodingForDevice = true);
      final out =
          await minisTranscodeToH264ForDevicePlayback(_activeVideoFile.path);
      if (mounted) setState(() => _reencodingForDevice = false);
      if (out != null && mounted) {
        if (_repairTempPath != null && _repairTempPath != out) {
          try { await File(_repairTempPath!).delete(); } catch (_) {}
        }
        _repairTempPath = out;
        _activeVideoFile = File(out);
        await _loadVideo();
        return;
      }
    }
    if (_repairTempPath != null) {
      try { await File(_repairTempPath!).delete(); } catch (_) {}
      _repairTempPath = null;
    }
    _activeVideoFile = widget.videoFile;
    if (mounted) {
      setState(() {
        _loadFailed = true;
        _reencodingForDevice = false;
      });
    }
  }

  Future<void> _loadVideo() async {
    try {
      _controller?.dispose();
      final ctrl = VideoPlayerController.file(_activeVideoFile);
      _controller = ctrl;
      await ctrl.initialize();
      if (!mounted) return;
      if (ctrl.value.hasError) {
        await _failLoadOrReencode();
        return;
      }
      await minisWaitForVideoControllerDuration(ctrl);
      if (!mounted) return;
      var total = ctrl.value.duration.inMilliseconds;
      if (total <= 0) {
        // Fallback: use native duration probe
        total = await RetrytechPlugin.shared.getVideoDurationMs(
          _activeVideoFile.path,
        );
      }
      if (total <= 0) {
        await _failLoadOrReencode();
        return;
      }
      final capReq = widget.maxOutputDuration?.inMilliseconds ?? 30000;
      final maxSegMs = math.min(capReq, total);
      setState(() {
        _totalMs = total.toDouble();
        _startMs = 0;
        _endMs = math.min(total.toDouble(), maxSegMs.toDouble());
        _videoLoaded = true;
      });
    } catch (e) {
      debugPrint('minis trimmer loadVideo: $e');
      await _failLoadOrReencode();
    }
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _controller?.dispose();
    if (_repairTempPath != null) {
      final path = _repairTempPath!;
      _repairTempPath = null;
      unawaited(File(path).delete().catchError((_) => File(path)));
    }
    super.dispose();
  }

  void _startPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final pos = c.value.position.inMilliseconds.toDouble();
      if (pos >= _endMs) {
        c.seekTo(Duration(milliseconds: _startMs.round()));
      }
      if (mounted) setState(() => _isPlaying = c.value.isPlaying);
    });
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      _positionTimer?.cancel();
      setState(() => _isPlaying = false);
    } else {
      final pos = c.value.position.inMilliseconds.toDouble();
      if (pos < _startMs || pos >= _endMs) {
        c.seekTo(Duration(milliseconds: _startMs.round()));
      }
      c.play();
      _startPositionPolling();
      setState(() => _isPlaying = true);
    }
  }

  String _formatMs(double ms) {
    final sec = (ms / 1000).round();
    final m = sec ~/ 60;
    final s = sec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _save() async {
    if (_endMs <= _startMs || _saving) return;
    setState(() => _saving = true);
    _controller?.pause();

    try {
      final dir = await getTemporaryDirectory();
      final outPath = p.join(
        dir.path,
        'minis_trim_${DateTime.now().microsecondsSinceEpoch}.mp4',
      );

      final result = await RetrytechPlugin.shared.trimVideo(
        inputPath: _activeVideoFile.path,
        outputPath: outPath,
        startMs: _startMs.round(),
        endMs: _endMs.round(),
      );

      if (!mounted) return;
      if (result.isNotEmpty && File(result).existsSync()) {
        final spanMs =
            (_endMs - _startMs).round().clamp(1, 24 * 60 * 60 * 1000);
        Navigator.of(context, rootNavigator: true).pop(
          MinisReelTrimResult(path: result, durationMs: spanMs),
        );
        return;
      }
      showMinisToast(context, 'Trim failed. Please try again.');
    } catch (e) {
      debugPrint('minis trim save error: $e');
      if (mounted) showMinisToast(context, 'Trim failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadFailed) {
      // Bug 10 fix: provide Retry and Close so the user is never stranded.
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('Trim clip'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop<MinisReelTrimResult>(),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_off_outlined,
                    size: 48, color: Colors.white54),
                const SizedBox(height: 20),
                const Text(
                  'Could not load this clip for trimming.\n'
                  'The file may be in an unsupported format.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, height: 1.45),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () {
                    if (_repairTempPath != null) {
                      try {
                        File(_repairTempPath!).deleteSync();
                      } catch (_) {}
                      _repairTempPath = null;
                    }
                    _activeVideoFile = widget.videoFile;
                    _h264RepairTried = false;
                    setState(() {
                      _loadFailed = false;
                      _videoLoaded = false;
                    });
                    unawaited(_loadVideo());
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side:
                        const BorderSide(color: Colors.white38),
                  ),
                  icon: const Icon(Icons.refresh, size: 20),
                  label: const Text('Try again'),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => Navigator.of(context, rootNavigator: true)
                      .pop<MinisReelTrimResult>(),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final accent = Theme.of(context).colorScheme.primary;
    final capSec = widget.maxOutputDuration?.inSeconds;
    final ctrl = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          capSec != null ? 'Trim (max ${capSec}s)' : 'Trim clip',
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
                    if (ctrl != null && ctrl.value.isInitialized)
                      Center(
                        child: AspectRatio(
                          aspectRatio: ctrl.value.aspectRatio,
                          child: VideoPlayer(ctrl),
                        ),
                      )
                    else
                      const ColoredBox(color: Colors.black),
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
                                'Loading...',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // -- Trim range slider --
              if (_videoLoaded && _totalMs > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: accent,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: accent,
                          overlayColor: accent.withAlpha(40),
                          rangeThumbShape: const RoundRangeSliderThumbShape(
                            enabledThumbRadius: 10,
                          ),
                        ),
                        child: RangeSlider(
                          min: 0,
                          max: _totalMs,
                          values: RangeValues(_startMs, _endMs),
                          onChanged: (v) {
                            setState(() {
                              _startMs = v.start;
                              _endMs = v.end;
                            });
                          },
                          onChangeEnd: (v) {
                            _controller?.seekTo(
                              Duration(milliseconds: v.start.round()),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatMs(_startMs),
                              style: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                            ),
                            Text(
                              'Duration: ${_formatMs(_endMs - _startMs)}',
                              style: const TextStyle(
                                color: Colors.white, fontSize: 13,
                                fontWeight: FontWeight.w600),
                            ),
                            Text(
                              _formatMs(_endMs),
                              style: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Center(
                child: IconButton(
                  iconSize: 64,
                  color: Colors.white,
                  onPressed: _videoLoaded ? _togglePlayPause : null,
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
          if (_reencodingForDevice)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0xCC000000),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 12),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          'Preparing a compatible copy…',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white70,
                            height: 1.4,
                            fontSize: 15,
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
