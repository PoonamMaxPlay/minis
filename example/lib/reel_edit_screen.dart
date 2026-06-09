import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

import 'create_feed_screen.dart';

/// Reel editor screen modelled after Banuba VE-SDK V2 layout:
///   * top: back / undo / redo / Next
///   * centre: video preview with tap-to-play overlay
///   * lower: horizontal thumbnail strip with current-position scrubber
///   * bottom: scrollable row of action chips
///
/// Trim + speed flows hit `MinisVidEdit` (Media3 Transformer under the
/// hood). The remaining chips (music / volume / filters / text / stickers)
/// are wired with placeholder handlers so the layout is fully exercisable
/// while the dedicated editors land.
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
  final bool _busy = false;
  double _playbackSpeed = 1.0;
  List<Uint8List> _thumbnails = const [];
  bool _thumbsLoading = false;
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    final c = VideoPlayerController.file(File(_activePath));
    await c.initialize();
    await c.setLooping(true);
    await c.setPlaybackSpeed(_playbackSpeed);
    await c.play();
    if (!mounted) {
      await c.dispose();
      return;
    }
    setState(() => _ctrl = c);
    unawaited(_loadThumbs(_activePath));
  }

  Future<void> _loadThumbs(String path) async {
    if (_thumbsLoading) return;
    setState(() => _thumbsLoading = true);
    try {
      final thumbs = await MinisVidEdit.instance.thumbnailStrip(
        path: path,
        count: 12,
        width: 96,
        height: 96,
      );
      if (!mounted) return;
      setState(() => _thumbnails = thumbs);
    } catch (_) {
      if (mounted) setState(() => _thumbnails = const []);
    } finally {
      if (mounted) setState(() => _thumbsLoading = false);
    }
  }

  Future<void> _swapController(String path, {bool pushUndo = true}) async {
    final old = _ctrl;
    final previous = _activePath;
    setState(() {
      _ctrl = null;
      _activePath = path;
      if (pushUndo) {
        _undoStack.add(previous);
        _redoStack.clear();
      }
    });
    await old?.dispose();
    await _init();
  }

  Future<void> _openTrimmer() async {
    if (_trimming) return;
    if (!minisReelClipTrimmerPlatformSupported()) {
      _toast('Trim works on Android / iOS only.');
      return;
    }
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

  Future<void> _openSpeedPicker() async {
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _SpeedPickerSheet(current: _playbackSpeed),
    );
    if (picked == null || picked == _playbackSpeed) return;
    setState(() => _playbackSpeed = picked);
    await _ctrl?.setPlaybackSpeed(picked);
  }

  void _comingSoon(String label) => _toast('$label coming soon');

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _onUndo() async {
    if (_undoStack.isEmpty) return;
    final last = _undoStack.removeLast();
    _redoStack.add(_activePath);
    await _swapController(last, pushUndo: false);
  }

  Future<void> _onRedo() async {
    if (_redoStack.isEmpty) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_activePath);
    await _swapController(next, pushUndo: false);
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
    final canUndo = _undoStack.isNotEmpty;
    final canRedo = _redoStack.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              onBack: () => Get.back<void>(),
              onUndo: canUndo ? _onUndo : null,
              onRedo: canRedo ? _onRedo : null,
              onNext: _onNext,
            ),
            Expanded(
              child: Stack(
                children: [
                  _ReelBackdrop(controller: _ctrl, onTap: _onTogglePlay),
                  if (_busy)
                    const ColoredBox(
                      color: Color(0x99000000),
                      child: Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            _TimelineStrip(
              thumbnails: _thumbnails,
              loading: _thumbsLoading,
              controller: _ctrl,
            ),
            _ActionBar(
              entries: [
                _ActionEntry(
                  icon: Icons.content_cut,
                  label: 'Trim',
                  onTap: _trimming ? null : _openTrimmer,
                ),
                _ActionEntry(
                  icon: Icons.speed,
                  label: '$_playbackSpeed×',
                  onTap: _openSpeedPicker,
                ),
                _ActionEntry(
                  icon: Icons.music_note,
                  label: 'Music',
                  onTap: () => _comingSoon('Music'),
                ),
                _ActionEntry(
                  icon: Icons.volume_up,
                  label: 'Volume',
                  onTap: () => _comingSoon('Volume'),
                ),
                _ActionEntry(
                  icon: Icons.auto_awesome,
                  label: 'Effects',
                  onTap: () => _comingSoon('Effects'),
                ),
                _ActionEntry(
                  icon: Icons.filter_vintage,
                  label: 'Filters',
                  onTap: () => _comingSoon('Filters'),
                ),
                _ActionEntry(
                  icon: Icons.text_fields,
                  label: 'Text',
                  onTap: () => _comingSoon('Text'),
                ),
                _ActionEntry(
                  icon: Icons.emoji_emotions,
                  label: 'Stickers',
                  onTap: () => _comingSoon('Stickers'),
                ),
                _ActionEntry(
                  icon: Icons.mic,
                  label: 'Voiceover',
                  onTap: () => _comingSoon('Voiceover'),
                ),
                _ActionEntry(
                  icon: Icons.closed_caption,
                  label: 'Captions',
                  onTap: () => _comingSoon('Captions'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────
// Layout primitives.
// ───────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onBack,
    required this.onUndo,
    required this.onRedo,
    required this.onNext,
  });

  final VoidCallback onBack;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
          const Spacer(),
          IconButton(
            onPressed: onUndo,
            tooltip: 'Undo',
            icon: Icon(
              Icons.undo,
              color: onUndo == null ? Colors.white24 : Colors.white,
            ),
          ),
          IconButton(
            onPressed: onRedo,
            tooltip: 'Redo',
            icon: Icon(
              Icons.redo,
              color: onRedo == null ? Colors.white24 : Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.tealAccent.shade400,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
            ),
            child: const Text(
              'Next',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineStrip extends StatelessWidget {
  const _TimelineStrip({
    required this.thumbnails,
    required this.loading,
    required this.controller,
  });

  final List<Uint8List> thumbnails;
  final bool loading;
  final VideoPlayerController? controller;

  @override
  Widget build(BuildContext context) {
    const stripHeight = 56.0;
    final tileWidth = stripHeight * 9 / 16;
    return Container(
      height: stripHeight + 16,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: const Color(0xFF050505),
      child: thumbnails.isEmpty
          ? Center(
              child: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white54,
                      ),
                    )
                  : const Text(
                      'Generating preview…',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
            )
          : Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: thumbnails.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 2),
                    itemBuilder: (_, i) => SizedBox(
                      width: tileWidth,
                      child: Image.memory(
                        thumbnails[i],
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ),
                if (controller != null && controller!.value.isInitialized)
                  Positioned.fill(
                    child: ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: controller!,
                      builder: (context, v, _) {
                        final total = v.duration.inMilliseconds;
                        if (total <= 0) return const SizedBox.shrink();
                        final progress = v.position.inMilliseconds / total;
                        return LayoutBuilder(
                          builder: (_, c) {
                            final x = (c.maxWidth * progress)
                                .clamp(0.0, c.maxWidth);
                            return Stack(
                              children: [
                                Positioned(
                                  left: x - 1,
                                  top: 0,
                                  bottom: 0,
                                  width: 2,
                                  child: Container(color: Colors.white),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ActionEntry {
  const _ActionEntry({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.entries});

  final List<_ActionEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 96,
      color: const Color(0xFF0A0A0A),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final e = entries[i];
          final disabled = e.onTap == null;
          return InkWell(
            onTap: e.onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 64,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 44,
                    width: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C1E),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      e.icon,
                      color: disabled ? Colors.white30 : Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    e.label,
                    style: TextStyle(
                      color: disabled ? Colors.white38 : Colors.white,
                      fontSize: 11,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SpeedPickerSheet extends StatelessWidget {
  const _SpeedPickerSheet({required this.current});

  final double current;

  @override
  Widget build(BuildContext context) {
    const options = [0.5, 0.75, 1.0, 1.5, 2.0];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                'Playback speed',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final v in options)
                  ChoiceChip(
                    label: Text('$v×'),
                    selected: v == current,
                    onSelected: (_) => Navigator.of(context).pop(v),
                    selectedColor: Colors.tealAccent.shade400,
                    labelStyle: TextStyle(
                      color: v == current ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                    backgroundColor: const Color(0xFF1C1C1E),
                  ),
              ],
            ),
          ],
        ),
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
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
