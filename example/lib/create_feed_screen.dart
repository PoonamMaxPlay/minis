import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

/// LoopIt parity: `enum CreateFeedType { feed, reel }`.
enum CreateFeedType { feed, reel }

/// Simplified port of LoopIt's `CreateFeedScreen`. Keeps the section layout
/// (preview → location → caption → toggles → post) without the LoopIt-only
/// dependencies (User, GetX controllers, hashtag/mention/location sheets,
/// URL-meta cards). Pure widget + local state.
class CreateFeedScreen extends StatefulWidget {
  const CreateFeedScreen({
    super.key,
    required this.createType,
    this.reelVideoPath,
    this.initialMediaPath,
  });

  final CreateFeedType createType;

  /// Reel video preloaded by Minis capture (`createType == reel`).
  final String? reelVideoPath;

  /// Feed media (image or video) preloaded by Minis capture
  /// (`createType == feed`). Type is auto-detected by extension/MIME.
  final String? initialMediaPath;

  @override
  State<CreateFeedScreen> createState() => _CreateFeedScreenState();
}

class _CreateFeedScreenState extends State<CreateFeedScreen> {
  final TextEditingController _caption = TextEditingController();
  final List<File> _images = [];
  File? _galleryVideo;
  VideoPlayerController? _videoCtrl;
  bool _allowComments = true;
  bool _posting = false;

  bool get _isReel => widget.createType == CreateFeedType.reel;
  String get _title => _isReel ? 'Create Reel' : 'Create Post';

  @override
  void initState() {
    super.initState();
    if (widget.reelVideoPath != null) {
      unawaited(_initVideo(widget.reelVideoPath!));
    } else if (widget.initialMediaPath != null) {
      final path = widget.initialMediaPath!;
      if (_pathLooksLikeVideo(path)) {
        _galleryVideo = File(path);
        unawaited(_initGalleryVideo());
      } else {
        _images.add(File(path));
      }
    }
  }

  Future<void> _initVideo(String path) async {
    final ctrl = VideoPlayerController.file(File(path));
    await ctrl.initialize();
    await ctrl.setLooping(true);
    await ctrl.play();
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    setState(() => _videoCtrl = ctrl);
  }

  static bool _pathLooksLikeVideo(String path) {
    final lower = path.toLowerCase();
    const exts = ['.mp4', '.mov', '.m4v', '.webm', '.mkv', '.3gp', '.avi'];
    for (final e in exts) {
      if (lower.endsWith(e)) return true;
    }
    return false;
  }

  @override
  void dispose() {
    _caption.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    final picked = await NativePicker.pickMedia(multi: true, types: const ['image']);
    if (picked.isEmpty) return;
    setState(() {
      _galleryVideo = null;
      _disposeVideoCtrl();
      for (final x in picked) {
        _images.add(File(x.path));
      }
    });
  }

  Future<void> _pickFromGallery() async {
    final items = await NativePicker.pickMedia(multi: false);
    if (items.isEmpty) return;
    final picked = items.first;
    final isVideo = _looksLikeVideo(picked.path, picked.mime);
    if (isVideo) {
      setState(() {
        _images.clear();
        _galleryVideo = File(picked.path);
      });
      unawaited(_initGalleryVideo());
    } else {
      setState(() {
        _galleryVideo = null;
        _disposeVideoCtrl();
        _images.add(File(picked.path));
      });
    }
  }

  Future<void> _pickFromCamera() async {
    final source = await showModalBottomSheet<_CamSource>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera, color: Colors.white),
              title: const Text('Take photo',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, _CamSource.photo),
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.white),
              title: const Text('Record video',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, _CamSource.video),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    PickedItem? picked;
    if (source == _CamSource.photo) {
      picked = await NativePicker.pickImage(source: 'camera');
    } else {
      picked = await NativePicker.pickVideo(source: 'camera');
    }
    if (picked == null) return;
    if (source == _CamSource.video) {
      setState(() {
        _images.clear();
        _galleryVideo = File(picked!.path);
      });
      unawaited(_initGalleryVideo());
    } else {
      setState(() {
        _galleryVideo = null;
        _disposeVideoCtrl();
        _images.add(File(picked!.path));
      });
    }
  }

  Future<void> _initGalleryVideo() async {
    final f = _galleryVideo;
    if (f == null) return;
    _disposeVideoCtrl();
    final ctrl = VideoPlayerController.file(f);
    await ctrl.initialize();
    await ctrl.setLooping(true);
    await ctrl.play();
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    setState(() => _videoCtrl = ctrl);
  }

  void _disposeVideoCtrl() {
    final c = _videoCtrl;
    if (c != null) {
      unawaited(c.dispose());
      _videoCtrl = null;
    }
  }

  bool _looksLikeVideo(String path, String? mime) {
    final mt = mime?.toLowerCase();
    if (mt != null && mt.isNotEmpty) {
      if (mt.startsWith('video/')) return true;
      if (mt.startsWith('image/')) return false;
    }
    final lower = path.toLowerCase();
    const exts = ['.mp4', '.mov', '.m4v', '.webm', '.mkv', '.3gp', '.avi'];
    for (final e in exts) {
      if (lower.endsWith(e)) return true;
    }
    return false;
  }

  Future<void> _post() async {
    if (_posting) return;
    setState(() => _posting = true);

    // Snapshot the primary media for share/save before the input fields get
    // cleared in the success path.
    final mediaPaths = <String>[
      if (widget.reelVideoPath != null) widget.reelVideoPath!,
      if (_galleryVideo != null) _galleryVideo!.path,
      ..._images.map((f) => f.path),
    ];

    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    unawaited(MinisTelemetry.instance.emit('feed.post', {
      'op': 'post',
      'kind': _isReel ? 'reel' : 'feed',
      'count': mediaPaths.length,
      'result': 'ok',
    }));

    // saveToGallery is a no-op when the user denied photos-add; the call
    // returns null and we don't surface an error.
    for (final p in mediaPaths) {
      try {
        await NativePicker.saveToGallery(path: p, album: 'Minis');
      } catch (_) {}
    }

    setState(() {
      _posting = false;
      _caption.clear();
      _images.clear();
      _galleryVideo = null;
      _disposeVideoCtrl();
    });
    Get.back<void>();
    Get.snackbar(
      _isReel ? 'Reel posted' : 'Post created',
      _caption.text.isEmpty ? '(no caption)' : _caption.text,
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 4),
      backgroundColor: const Color(0xE61C1C1E),
      colorText: Colors.white,
      margin: const EdgeInsets.all(16),
      borderRadius: 10,
      mainButton: mediaPaths.isEmpty
          ? null
          : TextButton(
              onPressed: () {
                unawaited(NativeShare.share(
                  paths: mediaPaths,
                  text: _caption.text.isEmpty ? null : _caption.text,
                ));
              },
              child: const Text('Share', style: TextStyle(color: Colors.tealAccent)),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _AppBar(title: _title, onClose: () => Get.back<void>()),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _previewSection(),
                    const _DividerRow(label: 'Location', icon: Icons.place_outlined),
                    _CaptionField(controller: _caption),
                    const SizedBox(height: 8),
                    _CommentToggle(
                      value: _allowComments,
                      onChanged: (v) => setState(() => _allowComments = v),
                    ),
                    const _DividerRow(label: 'Tag people', icon: Icons.alternate_email),
                    const _DividerRow(label: 'Hashtags', icon: Icons.tag),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed: _posting ? null : _post,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.tealAccent.shade400,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: _posting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : Text(_isReel ? 'Post Reel' : 'Post'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewSection() {
    if (_isReel) {
      return _ReelPreviewCard(controller: _videoCtrl);
    }
    if (_galleryVideo != null) {
      return _GalleryVideoPreview(
        controller: _videoCtrl,
        onClear: () {
          setState(() {
            _galleryVideo = null;
            _disposeVideoCtrl();
          });
        },
      );
    }
    if (_images.isNotEmpty) {
      return _ImageGrid(images: _images, onAddMore: _pickImages);
    }
    // LoopIt parity: `mediaSelectionView` — gallery + camera side by side.
    return _MediaSelectionRow(
      onGalleryTap: _pickFromGallery,
      onCameraTap: _pickFromCamera,
    );
  }
}

enum _CamSource { photo, video }

class _AppBar extends StatelessWidget {
  const _AppBar({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _ReelPreviewCard extends StatelessWidget {
  const _ReelPreviewCard({this.controller});

  final VideoPlayerController? controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: AspectRatio(
        aspectRatio: 9 / 16,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(
            color: Colors.white10,
            child: c == null || !c.value.isInitialized
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white54),
                  )
                : FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: c.value.size.width,
                      height: c.value.size.height,
                      child: VideoPlayer(c),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// LoopIt parity: `mediaSelectionView` — two equal-width tiles, gallery left,
/// camera right (icUploadGallery + icCamera in LoopIt).
class _MediaSelectionRow extends StatelessWidget {
  const _MediaSelectionRow({
    required this.onGalleryTap,
    required this.onCameraTap,
  });

  final VoidCallback onGalleryTap;
  final VoidCallback onCameraTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: _MediaPickTile(
              icon: Icons.photo_library_outlined,
              label: 'Gallery',
              onTap: onGalleryTap,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MediaPickTile(
              icon: Icons.photo_camera_outlined,
              label: 'Camera',
              onTap: onCameraTap,
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaPickTile extends StatelessWidget {
  const _MediaPickTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 90,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white70, size: 28),
            const SizedBox(height: 6),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _GalleryVideoPreview extends StatelessWidget {
  const _GalleryVideoPreview({
    required this.controller,
    required this.onClear,
  });

  final VideoPlayerController? controller;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: ColoredBox(
                  color: Colors.white10,
                  child: c == null || !c.value.isInitialized
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: Colors.white54),
                        )
                      : FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: c.value.size.width,
                            height: c.value.size.height,
                            child: VideoPlayer(c),
                          ),
                        ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onClear,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child:
                        Icon(Icons.close, color: Colors.white, size: 18),
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

class _ImageGrid extends StatelessWidget {
  const _ImageGrid({required this.images, required this.onAddMore});

  final List<File> images;
  final VoidCallback onAddMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: images.length + 1,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
        ),
        itemBuilder: (context, index) {
          if (index == images.length) {
            return InkWell(
              onTap: onAddMore,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(Icons.add, color: Colors.white70),
              ),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(images[index], fit: BoxFit.cover),
          );
        },
      ),
    );
  }
}

class _DividerRow extends StatelessWidget {
  const _DividerRow({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Divider(height: 1, color: Colors.white12),
        InkWell(
          onTap: () {},
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Icon(icon, color: Colors.white70, size: 20),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 14)),
                ),
                const Icon(Icons.chevron_right,
                    color: Colors.white38, size: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CaptionField extends StatelessWidget {
  const _CaptionField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: TextField(
        controller: controller,
        maxLines: 4,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        decoration: const InputDecoration(
          hintText: 'Write a caption…',
          hintStyle: TextStyle(color: Colors.white38),
          border: InputBorder.none,
        ),
      ),
    );
  }
}

class _CommentToggle extends StatelessWidget {
  const _CommentToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.chat_bubble_outline,
              color: Colors.white70, size: 20),
          const SizedBox(width: 14),
          const Expanded(
            child: Text('Allow comments',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.tealAccent.shade400,
          ),
        ],
      ),
    );
  }
}
