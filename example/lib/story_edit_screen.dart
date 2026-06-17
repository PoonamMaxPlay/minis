import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

import 'minis_example_save.dart';

/// Simplified port of LoopIt's `CameraEditScreen` for story uploads.
/// LoopIt story flow: `openMinisStoryCaptureAndEdit` →
/// `Get.to(CameraEditScreen(content: ...))`.
///
/// Layout parity:
///   - Full-bleed preview (image or video) clipped to rounded card.
///   - Top-right tool icons: duration (image-only stub), text, filter, bg,
///     music (no-op placeholders — the example does not pull in LoopIt's
///     ColorFiltersView / SelectedMusicView).
///   - Bottom action row: Discard / Post (CameraEditActionButtons).
class StoryEditScreen extends StatefulWidget {
  const StoryEditScreen({super.key, required this.mediaPath});

  final String mediaPath;

  @override
  State<StoryEditScreen> createState() => _StoryEditScreenState();
}

class _StoryEditScreenState extends State<StoryEditScreen> {
  static const List<int> _storyDurations = [3, 5, 7, 10, 15];
  static const _videoExt = {
    '.mp4', '.mov', '.m4v', '.webm', '.mkv', '.3gp', '.avi'
  };

  VideoPlayerController? _videoCtrl;
  bool _isVideo = false;
  int _durationIndex = 1;
  bool _posting = false;
  String? _editedPath;

  String get _activeMediaPath => _editedPath ?? widget.mediaPath;

  @override
  void initState() {
    super.initState();
    _isVideo = _videoExt.contains(NativePaths.extension(widget.mediaPath).toLowerCase());
    if (_isVideo) {
      unawaited(_initVideo());
    }
  }

  Future<void> _initVideo() async {
    final ctrl = VideoPlayerController.file(File(widget.mediaPath));
    await ctrl.initialize();
    await ctrl.setLooping(true);
    await ctrl.play();
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    setState(() => _videoCtrl = ctrl);
  }

  @override
  void dispose() {
    _videoCtrl?.dispose();
    super.dispose();
  }

  void _cycleDuration() {
    setState(() {
      _durationIndex = (_durationIndex + 1) % _storyDurations.length;
    });
  }

  Future<void> _discard() async {
    Get.back<void>();
  }

  Future<void> _post() async {
    if (_posting) return;
    setState(() => _posting = true);
    await MinisExampleSave.saveAndNotify(_activeMediaPath);
    if (!mounted) return;
    setState(() => _posting = false);
    Get.back<void>();
  }

  /// Native image editor (improvement2.md). Opens the GPU pipeline (GLES3
  /// Android / Metal iOS) with the captured photo; returned path replaces
  /// the working media so the post step uploads the edited frame.
  Future<void> _openImageEditor() async {
    if (_isVideo) return;
    final edited = await MinisImageEditor.openFromFile(
      context,
      _activeMediaPath,
    );
    if (!mounted) return;
    if (edited != null) {
      setState(() => _editedPath = edited);
      unawaited(MinisTelemetry.instance.emit('story.edit', {
        'op': 'imageEdit',
        'result': 'ok',
      }));
    }
  }

  void _onPlayPauseToggle() {
    final c = _videoCtrl;
    if (c == null) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        minimum: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6.0, vertical: 20),
                child: Stack(
                  children: [
                    Positioned.fill(child: _buildPreview()),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _TopTools(
                          isVideo: _isVideo,
                          durationLabel: '${_storyDurations[_durationIndex]}s',
                          onDurationTap: _isVideo ? null : _cycleDuration,
                          onEditTap: _isVideo ? null : _openImageEditor,
                        ),
                        const SizedBox.shrink(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            _ActionButtons(
              posting: _posting,
              onDiscard: _discard,
              onPost: _post,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final radius = BorderRadius.circular(15);
    if (_isVideo) {
      final c = _videoCtrl;
      if (c == null || !c.value.isInitialized) {
        return ClipRRect(
          borderRadius: radius,
          child: const ColoredBox(
            color: Colors.black,
            child: Center(
              child: CircularProgressIndicator(color: Colors.white54),
            ),
          ),
        );
      }
      final size = c.value.size;
      final fit = size.width < size.height ? BoxFit.cover : BoxFit.fitWidth;
      return InkWell(
        onTap: _onPlayPauseToggle,
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ColoredBox(
                color: Colors.black,
                child: SizedBox.expand(
                  child: FittedBox(
                    fit: fit,
                    child: SizedBox(
                      width: size.width,
                      height: size.height,
                      child: VideoPlayer(c),
                    ),
                  ),
                ),
              ),
              ValueListenableBuilder(
                valueListenable: c,
                builder: (context, value, _) => AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: value.isPlaying ? 0 : 1,
                  child: Container(
                    height: 60,
                    width: 60,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.play_arrow,
                        color: Colors.white, size: 35),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(
          child: Image.file(
            File(_activeMediaPath),
            key: ValueKey<String>(_activeMediaPath),
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

class _TopTools extends StatelessWidget {
  const _TopTools({
    required this.isVideo,
    required this.durationLabel,
    required this.onDurationTap,
    required this.onEditTap,
  });

  final bool isVideo;
  final String durationLabel;
  final VoidCallback? onDurationTap;
  final VoidCallback? onEditTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (!isVideo)
            _RoundIcon(
              onTap: onDurationTap,
              child: Center(
                child: Text(
                  durationLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          if (!isVideo) const SizedBox(width: 10),
          if (!isVideo)
            _RoundIcon(
              onTap: onEditTap,
              child: const Icon(Icons.tune, color: Colors.white, size: 20),
            ),
          if (!isVideo) const SizedBox(width: 10),
          if (!isVideo)
            const _RoundIcon(child: Icon(Icons.text_fields, color: Colors.white, size: 20)),
          if (!isVideo) const SizedBox(width: 10),
          const _RoundIcon(child: Icon(Icons.filter, color: Colors.white, size: 20)),
          const SizedBox(width: 10),
          const _RoundIcon(child: Icon(Icons.color_lens_outlined, color: Colors.white, size: 20)),
          const SizedBox(width: 10),
          const _RoundIcon(child: Icon(Icons.music_note, color: Colors.white, size: 20)),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 36,
        width: 36,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 1),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  const _ActionButtons({
    required this.posting,
    required this.onDiscard,
    required this.onPost,
  });

  final bool posting;
  final VoidCallback onDiscard;
  final VoidCallback onPost;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30.0),
      child: Row(
        children: [
          Expanded(
            child: _BtnTile(
              onTap: posting ? null : onDiscard,
              title: 'Discard',
              background: Colors.white12,
              foreground: Colors.white70,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: posting
                ? const SizedBox(
                    height: 44,
                    child: Center(
                      child: SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.tealAccent,
                        ),
                      ),
                    ),
                  )
                : _BtnTile(
                    onTap: onPost,
                    title: 'Post',
                    background: Colors.tealAccent.shade400,
                    foreground: Colors.black,
                  ),
          ),
        ],
      ),
    );
  }
}

class _BtnTile extends StatelessWidget {
  const _BtnTile({
    required this.onTap,
    required this.title,
    required this.background,
    required this.foreground,
  });

  final VoidCallback? onTap;
  final String title;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: foreground,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
