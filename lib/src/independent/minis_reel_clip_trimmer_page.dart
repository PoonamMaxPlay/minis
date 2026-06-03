import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:loopit_minis/src/sys/paths.dart';
import 'package:loopit_minis/src/sys/video_player_shim.dart';
import 'package:loopit_minis/src/videdit/videdit_engine.dart';
import 'package:loopit_minis/src/videdit/videdit_types.dart';

/// Returns true once the native VidEdit engine reports `engineAvailable`.
/// Capture flows hide the **Trim** action when this is false.
bool minisReelClipTrimmerPlatformSupported() {
  if (!MinisVidEdit.instance.isPlatformEligible) return false;
  return MinisVidEdit.instance.isAvailableSync;
}

/// Result returned by [MinisReelClipTrimmerPage.open].
class MinisReelTrimResult {
  const MinisReelTrimResult({required this.path, required this.durationMs});

  final String path;
  final int durationMs;
}

/// Full-screen trimmer. Builds a scrub strip via
/// [MinisVidEdit.thumbnailStrip], drives playback through a
/// [VideoPlayerController] (the in-plugin native shim), and hands the final
/// range to [MinisVidEdit.trim] when the user accepts.
class MinisReelClipTrimmerPage extends StatefulWidget {
  const MinisReelClipTrimmerPage({
    super.key,
    required this.videoFile,
    this.maxOutputDuration,
  });

  final File videoFile;
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
  State<MinisReelClipTrimmerPage> createState() => _MinisReelClipTrimmerPageState();
}

class _MinisReelClipTrimmerPageState extends State<MinisReelClipTrimmerPage> {
  static const int _thumbCount = 12;

  VideoPlayerController? _controller;
  List<Uint8List> _thumbs = const [];
  Duration _duration = Duration.zero;
  RangeValues _range = const RangeValues(0, 1);
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final controller = VideoPlayerController.file(widget.videoFile);
      await controller.initialize();
      await controller.setLooping(true);
      if (!mounted) { await controller.dispose(); return; }

      final ms = controller.value.duration.inMilliseconds;
      var initial = const RangeValues(0, 1);
      final cap = widget.maxOutputDuration;
      if (cap != null && cap.inMilliseconds > 0 && cap.inMilliseconds < ms) {
        initial = RangeValues(0, cap.inMilliseconds / ms);
      }

      List<Uint8List> thumbs = const [];
      try {
        thumbs = await MinisVidEdit.instance.thumbnailStrip(
          path: widget.videoFile.path,
          count: _thumbCount,
          width: 80,
          height: 80,
        );
      } catch (_) {
        thumbs = const [];
      }

      if (!mounted) { await controller.dispose(); return; }
      setState(() {
        _controller = controller;
        _duration = controller.value.duration;
        _range = initial;
        _thumbs = thumbs;
      });
      await controller.play();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  int get _startMs => (_range.start * _duration.inMilliseconds).round();
  int get _endMs => (_range.end * _duration.inMilliseconds).round();

  Future<void> _save() async {
    final controller = _controller;
    if (controller == null || _saving) return;
    setState(() => _saving = true);
    try {
      final dir = await NativePaths.cacheDir();
      if (dir == null) {
        setState(() { _saving = false; _error = 'cache dir unavailable'; });
        return;
      }
      final out = NativePaths.join([
        dir,
        'minis_trim_${DateTime.now().millisecondsSinceEpoch}.mp4',
      ]);
      final path = await MinisVidEdit.instance.trim(
        inputPath: widget.videoFile.path,
        outputPath: out,
        startMs: _startMs,
        endMs: _endMs,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(
        MinisReelTrimResult(path: path, durationMs: _endMs - _startMs),
      );
    } on VidEditUnsupportedError catch (e) {
      if (!mounted) return;
      setState(() { _saving = false; _error = e.detail ?? 'engine unavailable'; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _saving = false; _error = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
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
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: _saving
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: _error != null ? _buildError() : _buildEditor(),
    );
  }

  Widget _buildError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ),
      );

  Widget _buildEditor() {
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
        ),
        if (_thumbs.isNotEmpty)
          SizedBox(
            height: 56,
            child: Row(
              children: [
                for (final b in _thumbs)
                  Expanded(child: Image.memory(b, fit: BoxFit.cover)),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: RangeSlider(
            values: _range,
            min: 0,
            max: 1,
            divisions: 1000,
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            onChanged: (v) async {
              setState(() => _range = v);
              await controller.seekTo(Duration(milliseconds: _startMs));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            '${_formatMs(_startMs)} → ${_formatMs(_endMs)}'
            '   (${_formatMs(_endMs - _startMs)})',
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      ],
    );
  }

  String _formatMs(int ms) {
    final m = (ms ~/ 60000).toString().padLeft(2, '0');
    final s = ((ms ~/ 1000) % 60).toString().padLeft(2, '0');
    final cs = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
    return '$m:$s.$cs';
  }
}
