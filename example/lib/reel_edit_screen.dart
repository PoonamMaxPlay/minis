import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

import 'create_feed_screen.dart';

/// Reel preview after capture (LoopIt parity: `ReelPreviewEditLayout`).
/// Full-bleed video backdrop + bottom Discard / Next row.
/// "Next" routes to [CreateFeedScreen(reel)] for the final post step
/// (LoopIt: `CameraEditScreenController.handleContentUpload`).
class ReelEditScreen extends StatefulWidget {
  const ReelEditScreen({super.key, required this.videoPath});

  final String videoPath;

  @override
  State<ReelEditScreen> createState() => _ReelEditScreenState();
}

class _ReelEditScreenState extends State<ReelEditScreen> {
  VideoPlayerController? _ctrl;
  late String _activePath = widget.videoPath;
  bool _trimming = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final c = VideoPlayerController.file(File(_activePath));
    await c.initialize();
    await c.setLooping(true);
    await c.play();
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() => _ctrl = c);
  }

  Future<void> _swapController(String path) async {
    final old = _ctrl;
    setState(() {
      _ctrl = null;
      _activePath = path;
    });
    await old?.dispose();
    await _init();
  }

  /// Native trim (improvement3.md). Hidden when the VidEdit engine is not
  /// available (FFmpeg cross-build hasn't shipped artefacts yet); otherwise
  /// opens the in-plugin trimmer page backed by `MinisVidEdit.trim`.
  Future<void> _openTrimmer() async {
    if (_trimming) return;
    if (!minisReelClipTrimmerPlatformSupported()) return;
    setState(() => _trimming = true);
    try {
      final result = await MinisReelClipTrimmerPage.open(
        context,
        File(_activePath),
      );
      if (!mounted) return;
      if (result != null) {
        await _swapController(result.path);
        unawaited(MinisTelemetry.instance.emit('reel.trim', {
          'op': 'trim',
          'durationMs': result.durationMs,
          'result': 'ok',
        }));
      }
    } finally {
      if (mounted) setState(() => _trimming = false);
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _onTogglePlay() {
    final c = _ctrl;
    if (c == null) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  Future<void> _onDiscard() async {
    Get.back<void>();
  }

  Future<void> _onNext() async {
    await Get.to<void>(
      () => CreateFeedScreen(
        createType: CreateFeedType.reel,
        reelVideoPath: _activePath,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _ReelBackdrop(controller: _ctrl, onTap: _onTogglePlay),
          if (minisReelClipTrimmerPlatformSupported())
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12, right: 12),
                  child: FilledButton.icon(
                    onPressed: _trimming ? null : _openTrimmer,
                    icon: const Icon(Icons.content_cut, size: 18),
                    label: const Text('Trim'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.55),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    ),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _onDiscard,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Discard'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _onNext,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.tealAccent.shade400,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Next'),
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

class _ReelBackdrop extends StatelessWidget {
  const _ReelBackdrop({required this.controller, required this.onTap});

  final VideoPlayerController? controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: CircularProgressIndicator(color: Colors.white54),
        ),
      );
    }
    final size = c.value.size;
    final fit = size.height >= size.width ? BoxFit.cover : BoxFit.fitWidth;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: FittedBox(
              fit: fit,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: VideoPlayer(c),
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: c,
            builder: (context, value, _) => AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: value.isPlaying ? 0 : 1,
              child: Center(
                child: Container(
                  height: 64,
                  width: 64,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.play_arrow,
                      color: Colors.white, size: 36),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
