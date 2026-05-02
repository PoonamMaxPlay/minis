import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// 1×1 PNG used as the starting canvas when creating an overlay in
/// [ProImageEditor] (no separate image-picker dependency).
final Uint8List kMinisBlankPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

bool proVideoEditorThumbnailsSupported() {
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

bool proVideoEditorRenderExportSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

String? editorVideoLocalPath(EditorVideo v) {
  final f = v.file;
  if (f == null) return null;
  return f.path;
}

String formatDurationHuman(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) {
    return '${h}h ${m}m ${s}s';
  }
  if (m > 0) {
    return '${m}m ${s}s';
  }
  return '${s}s';
}

String formatFileSizeBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

Future<List<Uint8List>> sampleTimelineFrames({
  required EditorVideo video,
  required VideoMetadata meta,
  int count = 10,
}) async {
  final totalMs = meta.duration.inMilliseconds;
  if (totalMs <= 0) {
    throw StateError('Could not read video length.');
  }

  final stamps = List<Duration>.generate(
    count,
    (i) {
      final mid = (i + 0.5) / count;
      return Duration(milliseconds: (totalMs * mid).round());
    },
  );

  if (proVideoEditorThumbnailsSupported()) {
    try {
      final thumbs = await ProVideoEditor.instance.getThumbnails(
        ThumbnailConfigs(
          video: video,
          outputFormat: ThumbnailFormat.jpeg,
          timestamps: stamps,
          outputSize: const Size(240, 240),
          boxFit: ThumbnailBoxFit.cover,
        ),
      );
      if (thumbs.isNotEmpty) return thumbs;
    } catch (_) {}
  }

  final path = editorVideoLocalPath(video);
  if (path == null || path.isEmpty) {
    throw StateError(
      'This video is not stored as a local file. Save or pick a file from '
      'your device to see a filmstrip.',
    );
  }
  if (!File(path).existsSync()) {
    throw StateError('Video file is missing from disk.');
  }

  final out = <Uint8List>[];
  for (var i = 0; i < stamps.length; i++) {
    final tMs = stamps[i].inMilliseconds;
    final safeMs = tMs.clamp(0, totalMs - 1);
    final bytes = await VideoThumbnail.thumbnailData(
      video: path,
      imageFormat: ImageFormat.JPEG,
      maxWidth: 240,
      maxHeight: 240,
      quality: 80,
      timeMs: safeMs,
    );
    if (bytes != null && bytes.isNotEmpty) {
      out.add(bytes);
    }
  }

  if (out.isEmpty) {
    throw StateError(
      'Could not decode preview frames. Try another video or format (e.g. MP4).',
    );
  }

  return out;
}

class VideoClipInsightPage extends StatefulWidget {
  const VideoClipInsightPage({
    super.key,
    required this.video,
    this.initialMetadata,
  });

  final EditorVideo video;
  final VideoMetadata? initialMetadata;

  static Future<void> open(
    BuildContext context, {
    required EditorVideo video,
    VideoMetadata? initialMetadata,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoClipInsightPage(
          video: video,
          initialMetadata: initialMetadata,
        ),
      ),
    );
  }

  @override
  State<VideoClipInsightPage> createState() => _VideoClipInsightPageState();
}

class _VideoClipInsightPageState extends State<VideoClipInsightPage> {
  late Future<_InsightPayload> _load;

  @override
  void initState() {
    super.initState();
    _load = _buildPayload();
  }

  Future<_InsightPayload> _buildPayload() async {
    final meta = widget.initialMetadata ??
        await ProVideoEditor.instance.getMetadata(
          widget.video,
          checkStreamingOptimization: true,
        );

    bool? hasAudio;
    try {
      hasAudio = await ProVideoEditor.instance.hasAudioTrack(widget.video);
    } catch (_) {
      hasAudio = null;
    }

    List<Uint8List> frames;
    String? framesNote;
    try {
      frames = await sampleTimelineFrames(
        video: widget.video,
        meta: meta,
        count: 10,
      );
      if (!proVideoEditorThumbnailsSupported()) {
        framesNote =
            'Preview frames use your device decoder (Windows/Linux). '
            'On phone, the editor can use faster codec keyframes too.';
      }
    } catch (e) {
      frames = [];
      framesNote = e.toString();
    }

    return _InsightPayload(
      meta: meta,
      hasAudio: hasAudio,
      frames: frames,
      framesNote: framesNote,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pathLabel = editorVideoLocalPath(widget.video);
    final fileName = pathLabel != null && pathLabel.isNotEmpty
        ? pathLabel.split(RegExp(r'[/\\]')).last
        : 'Your video';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your clip'),
      ),
      body: FutureBuilder<_InsightPayload>(
        future: _load,
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'Could not open this video',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${snap.error}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Go back'),
                  ),
                ],
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading preview...'),
                ],
              ),
            );
          }

          final p = snap.data!;
          final m = p.meta;
          final w = m.resolution.width.round();
          final h = m.resolution.height.round();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                fileName,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'At a glance',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 12),
                      _factRow(
                        context,
                        Icons.schedule,
                        'Length',
                        formatDurationHuman(m.duration),
                      ),
                      _factRow(
                        context,
                        Icons.storage_outlined,
                        'File size',
                        formatFileSizeBytes(m.fileSize),
                      ),
                      _factRow(
                        context,
                        Icons.aspect_ratio,
                        'Picture',
                        '$w x $h pixels',
                      ),
                      _factRow(
                        context,
                        Icons.movie_outlined,
                        'Framerate',
                        m.frameRate != null
                            ? '${m.frameRate!.toStringAsFixed(1)} fps'
                            : '-',
                      ),
                      _factRow(
                        context,
                        Icons.volume_up_outlined,
                        'Sound',
                        p.hasAudio == null
                            ? 'Could not detect'
                            : (p.hasAudio! ? 'Yes' : 'No (silent)'),
                      ),
                      if (m.isOptimizedForStreaming == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Icon(
                                Icons.cloud_done_outlined,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Ready for streaming (moov atom at start).',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Filmstrip',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Skim the clip — preview before you edit.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (p.frames.isNotEmpty) ...[
                SizedBox(
                  height: 120,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: p.frames.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: AspectRatio(
                        aspectRatio: 9 / 16,
                        child: Image.memory(
                          p.frames[i],
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  ),
                ),
                if (p.framesNote != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    p.framesNote!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ] else ...[
                Text(
                  p.framesNote ?? 'No preview frames.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ],
              const SizedBox(height: 24),
              Theme(
                data: Theme.of(context),
                child: ExpansionTile(
                  title: const Text('Technical details'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    SelectableText(
                      'Duration (raw): ${m.duration}\n'
                      'Rotation: ${m.rotation}\n'
                      'Bitrate: ${m.bitrate}\n'
                      'Extension: ${m.extension}\n'
                      'Streaming-optimized: ${m.isOptimizedForStreaming}\n'
                      'Title: ${m.title}\n'
                      'Artist: ${m.artist}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static Widget _factRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightPayload {
  _InsightPayload({
    required this.meta,
    required this.hasAudio,
    required this.frames,
    required this.framesNote,
  });

  final VideoMetadata meta;
  final bool? hasAudio;
  final List<Uint8List> frames;
  final String? framesNote;
}

/// Entry: **pro_video_editor** tools plus optional overlay creation via
/// **pro_image_editor** (no `image_picker` / `file_picker`).
class MinisVideoHubPage extends StatefulWidget {
  const MinisVideoHubPage({super.key, this.initialVideoPath});

  /// Optional file path to open immediately (e.g. last stitched reel).
  final String? initialVideoPath;

  /// Pushes the hub onto the current navigator.
  static Future<void> open(
    BuildContext context, {
    String? initialVideoPath,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            MinisVideoHubPage(initialVideoPath: initialVideoPath),
      ),
    );
  }

  @override
  State<MinisVideoHubPage> createState() => _MinisVideoHubPageState();
}

class _MinisVideoHubPageState extends State<MinisVideoHubPage> {
  EditorVideo? _video;
  VideoMetadata? _meta;
  String? _busy;

  bool get _hasVideo => _video != null;

  static String _videoPathLabel(EditorVideo v) {
    return editorVideoLocalPath(v) ??
        v.assetPath ??
        v.networkUrl ??
        'video';
  }

  @override
  void initState() {
    super.initState();
    final path = widget.initialVideoPath;
    if (path != null && path.isNotEmpty) {
      try {
        if (File(path).existsSync()) {
          _video = EditorVideo.file(File(path));
          WidgetsBinding.instance.addPostFrameCallback((_) => _loadMeta());
        }
      } catch (_) {}
    }
  }

  Future<void> _loadMeta() async {
    final v = _video;
    if (v == null) return;
    setState(() => _busy = 'Reading metadata');
    try {
      final m = await ProVideoEditor.instance.getMetadata(v);
      if (mounted) setState(() => _meta = m);
    } catch (e) {
      if (mounted) _toast('Metadata failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Overlay for export: existing file path, or create/edit in [ProImageEditor].
  Future<String?> _promptOverlayImagePath(BuildContext sheetContext) async {
    final choice = await showModalBottomSheet<String>(
      context: sheetContext,
      showDragHandle: true,
      builder: (pickCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Use image file path'),
              onTap: () => Navigator.pop(pickCtx, 'path'),
            ),
            ListTile(
              leading: const Icon(Icons.draw_outlined),
              title: const Text('Create in Pro Image Editor'),
              subtitle: const Text(
                'Starts from a blank canvas; finish editing to use it.',
              ),
              onTap: () => Navigator.pop(pickCtx, 'editor'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return null;
    if (choice == 'path') {
      final ctl = TextEditingController();
      try {
        final typed = await showDialog<String>(
          context: context,
          builder: (dlgCtx) => AlertDialog(
            title: const Text('Overlay image path'),
            content: TextField(
              controller: ctl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dlgCtx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dlgCtx, ctl.text.trim()),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (typed == null || typed.isEmpty) return null;
        if (kIsWeb) {
          _toast('Local file paths are not supported on web.');
          return null;
        }
        if (!File(typed).existsSync()) {
          _toast('File not found.');
          return null;
        }
        return typed;
      } finally {
        ctl.dispose();
      }
    }
    if (choice == 'editor') {
      return _openProImageEditorForOverlay();
    }
    return null;
  }

  Future<String?> _openProImageEditorForOverlay() async {
    if (!mounted) return null;
    String? outPath;
    bool _popped = false;
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (editorCtx) => ProImageEditor.memory(
          kMinisBlankPngBytes,
          configs: const ProImageEditorConfigs(
            imageGeneration: ImageGenerationConfigs(
              outputFormat: OutputFormat.jpg,
              jpegQuality: 92,
            ),
          ),
          callbacks: ProImageEditorCallbacks(
            onImageEditingComplete: (Uint8List bytes) async {
              try {
                final dir = await getTemporaryDirectory();
                final path = p.join(
                  dir.path,
                  'minis_overlay_${DateTime.now().millisecondsSinceEpoch}.jpg',
                );
                await File(path).writeAsBytes(bytes, flush: true);
                outPath = path;
              } catch (e) {
                if (mounted) _toast('Could not save overlay: $e');
                outPath = null;
              }
              if (!_popped && editorCtx.mounted) {
                _popped = true;
                Navigator.of(editorCtx).pop();
              }
            },
            onCloseEditor: () {
              if (!_popped && editorCtx.mounted) {
                _popped = true;
                Navigator.of(editorCtx).pop();
              }
            },
          ),
        ),
      ),
    );
    return outPath;
  }

  Future<void> _pickVideo() async {
    final pathCtl = TextEditingController();
    final urlCtl = TextEditingController();
    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetCtx) {
          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 8,
              bottom: MediaQuery.viewInsetsOf(sheetCtx).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  kIsWeb ? 'Open video from URL' : 'Open video',
                  style: Theme.of(sheetCtx).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (!kIsWeb) ...[
                  TextField(
                    controller: pathCtl,
                    decoration: const InputDecoration(
                      labelText: 'Local file path',
                      border: OutlineInputBorder(),
                      hintText: r'C:\path\to\clip.mp4',
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: urlCtl,
                  decoration: const InputDecoration(
                    labelText: 'HTTPS URL',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    final path = pathCtl.text.trim();
                    final url = urlCtl.text.trim();
                    Navigator.pop(sheetCtx);
                    unawaited(
                      _applyVideoFromPickFields(
                        pathText: path,
                        urlText: url,
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      pathCtl.dispose();
      urlCtl.dispose();
    }
  }

  Future<void> _applyVideoFromPickFields({
    required String pathText,
    required String urlText,
  }) async {
    if (!mounted) return;
    if (kIsWeb) {
      if (urlText.isEmpty) {
        _toast('Enter an https:// video URL.');
        return;
      }
      if (!urlText.startsWith('http://') && !urlText.startsWith('https://')) {
        _toast('URL must start with http:// or https://');
        return;
      }
      setState(() {
        _video = EditorVideo.network(urlText);
        _meta = null;
      });
      await _loadMeta();
      return;
    }
    if (pathText.isNotEmpty) {
      final f = File(pathText);
      if (!f.existsSync()) {
        _toast('File not found: $pathText');
        return;
      }
      setState(() {
        _video = EditorVideo.file(f);
        _meta = null;
      });
      await _loadMeta();
      return;
    }
    if (urlText.isNotEmpty) {
      if (!urlText.startsWith('http://') && !urlText.startsWith('https://')) {
        _toast('URL must start with http:// or https://');
        return;
      }
      setState(() {
        _video = EditorVideo.network(urlText);
        _meta = null;
      });
      await _loadMeta();
      return;
    }
    _toast('Enter a file path or URL.');
  }

  Future<void> _openClipInsight() async {
    final v = _video;
    if (v == null) return;
    await VideoClipInsightPage.open(
      context,
      video: v,
      initialMetadata: _meta,
    );
    if (mounted) await _loadMeta();
  }

  Future<void> _openWaveform() async {
    final v = _video;
    if (v == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _MinisWaveformPage(video: v),
      ),
    );
  }

  Future<void> _extractAudio() async {
    final v = _video;
    if (v == null) return;
    setState(() => _busy = 'Checking audio');
    try {
      final has = await ProVideoEditor.instance.hasAudioTrack(v);
      if (!has) {
        _toast('This video has no audio track.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final outPath = p.join(
        dir.path,
        'minis_extract_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      setState(() => _busy = 'Extracting');
      await ProVideoEditor.instance.extractAudioToFile(
        outPath,
        AudioExtractConfigs(video: v, format: AudioFormat.aac),
      );
      _toast('Audio saved:\n$outPath');
    } on AudioNoTrackException {
      _toast('No audio track.');
    } catch (e) {
      _toast('Extract failed: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _mergeVideos() async {
    final controllers = <TextEditingController>[
      TextEditingController(),
      TextEditingController(),
    ];
    List<String>? paths;
    try {
      paths = await showDialog<List<String>>(
        context: context,
        builder: (dialogCtx) {
          return StatefulBuilder(
            builder: (context, setModal) {
              return AlertDialog(
                title: const Text('Merge clips'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Enter full paths to each video, in merge order.',
                        style: TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      for (var i = 0; i < controllers.length; i++) ...[
                        TextField(
                          controller: controllers[i],
                          decoration: InputDecoration(
                            labelText: 'Clip ${i + 1}',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () {
                            setModal(() {
                              controllers.add(TextEditingController());
                            });
                          },
                          icon: const Icon(Icons.add),
                          label: const Text('Add clip'),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () {
                      final raw = controllers
                          .map((c) => c.text.trim())
                          .where((s) => s.isNotEmpty)
                          .toList();
                      Navigator.pop(dialogCtx, raw);
                    },
                    child: const Text('Merge'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      for (final c in controllers) {
        c.dispose();
      }
    }

    if (!mounted) return;
    if (paths == null || paths.length < 2) {
      _toast('Enter at least two file paths.');
      return;
    }
    for (final path in paths) {
      if (!File(path).existsSync()) {
        _toast('File not found: $path');
        return;
      }
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final dir = await getTemporaryDirectory();
    final outPath = p.join(dir.path, 'minis_merge_$id.mp4');
    final data = VideoRenderData.withQualityPreset(
      id: id,
      videoSegments: paths
          .map((path) => VideoSegment(video: EditorVideo.file(File(path))))
          .toList(),
      qualityPreset: VideoQualityPreset.p1080High,
      outputFormat: VideoOutputFormat.mp4,
    );

    await _runRenderToFile(outPath, data, label: 'Merging clips');
  }

  Future<void> _openExportSheet() async {
    final v = _video;
    if (v == null) return;
    final meta = _meta ?? await ProVideoEditor.instance.getMetadata(v);
    if (!mounted) return;

    final startCtl = TextEditingController(text: '0');
    final endCtl = TextEditingController(
      text: (meta.duration.inMilliseconds / 1000).toStringAsFixed(1),
    );
    final speedCtl = TextEditingController(text: '1.0');
    final blurCtl = TextEditingController(text: '');
    final bitrateCtl = TextEditingController(text: '');
    var mute = false;
    var optimize = false;
    var warmFilter = false;
    var useOverlay = false;
    String? overlayPath;
    var preset = VideoQualityPreset.p1080;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModal) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 8,
                bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Export (trim, speed, filters, layers)',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<VideoQualityPreset>(
                      initialValue: preset,
                      decoration: const InputDecoration(
                        labelText: 'Quality preset',
                        border: OutlineInputBorder(),
                      ),
                      items: VideoQualityPreset.values
                          .map(
                            (e) => DropdownMenuItem(
                              value: e,
                              child: Text(e.name),
                            ),
                          )
                          .toList(),
                      onChanged: (q) {
                        if (q != null) setModal(() => preset = q);
                      },
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: startCtl,
                      decoration: const InputDecoration(
                        labelText: 'Trim start (seconds)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: endCtl,
                      decoration: const InputDecoration(
                        labelText: 'Trim end (seconds)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: speedCtl,
                      decoration: const InputDecoration(
                        labelText: 'Playback speed',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: blurCtl,
                      decoration: const InputDecoration(
                        labelText: 'Blur (optional, experimental)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: bitrateCtl,
                      decoration: const InputDecoration(
                        labelText: 'Bitrate override (optional, bits/s)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    SwitchListTile(
                      value: mute,
                      title: const Text('Strip audio (mute export)'),
                      onChanged: (b) => setModal(() => mute = b),
                    ),
                    SwitchListTile(
                      value: optimize,
                      title: const Text('Optimize for streaming (moov first)'),
                      onChanged: (b) => setModal(() => optimize = b),
                    ),
                    SwitchListTile(
                      value: warmFilter,
                      title: const Text('Warm color matrix'),
                      onChanged: (b) => setModal(() => warmFilter = b),
                    ),
                    SwitchListTile(
                      value: useOverlay,
                      title: const Text('Image overlay layer'),
                      onChanged: (b) => setModal(() => useOverlay = b),
                    ),
                    if (useOverlay)
                      OutlinedButton(
                        onPressed: () async {
                          final path = await _promptOverlayImagePath(ctx);
                          if (path != null && path.isNotEmpty) {
                            setModal(() => overlayPath = path);
                          }
                        },
                        child: Text(
                          overlayPath == null
                              ? 'Overlay image (path or editor)'
                              : p.basename(overlayPath!),
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _exportFromForm(
                          video: v,
                          preset: preset,
                          startSec: double.tryParse(startCtl.text) ?? 0,
                          endSec: double.tryParse(endCtl.text) ??
                              meta.duration.inMilliseconds / 1000,
                          speed: double.tryParse(speedCtl.text) ?? 1.0,
                          blur: double.tryParse(blurCtl.text.trim()),
                          bitrate: int.tryParse(bitrateCtl.text.trim()),
                          mute: mute,
                          optimize: optimize,
                          warmFilter: warmFilter,
                          overlayPath: useOverlay ? overlayPath : null,
                          metaDuration: meta.duration,
                        );
                      },
                      child: const Text('Export to file'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _exportFromForm({
    required EditorVideo video,
    required VideoQualityPreset preset,
    required double startSec,
    required double endSec,
    required double speed,
    required double? blur,
    required int? bitrate,
    required bool mute,
    required bool optimize,
    required bool warmFilter,
    required String? overlayPath,
    required Duration metaDuration,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final dir = await getTemporaryDirectory();
    final outPath = p.join(dir.path, 'minis_export_$id.mp4');

    final start = Duration(milliseconds: (startSec * 1000).round());
    var end = Duration(milliseconds: (endSec * 1000).round());
    if (end > metaDuration) end = metaDuration;
    if (start >= end) {
      _toast('Invalid trim range.');
      return;
    }

    final colorFilters = warmFilter
        ? <ColorFilter>[
            const ColorFilter(
              matrix: [
                1.0, 0.0, 0.0, 0.0, 18.0,
                0.0, 1.0, 0.0, 0.0, 8.0,
                0.0, 0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 0.0, 1.0, 0.0,
              ],
            ),
          ]
        : const <ColorFilter>[];

    List<ImageLayer>? layers;
    if (overlayPath != null && overlayPath.isNotEmpty) {
      layers = [
        ImageLayer(
          image: EditorLayerImage.file(overlayPath),
          offset: Offset.zero,
          startTime: start,
          endTime: end,
          animations: const [
            LayerAnimation(
              type: LayerAnimationType.fade,
              phase: AnimationPhase.animateIn,
              duration: Duration(milliseconds: 400),
              curve: AnimationCurve.easeOut,
            ),
          ],
        ),
      ];
    }

    final data = VideoRenderData.withQualityPreset(
      id: id,
      videoSegments: [VideoSegment(video: video)],
      qualityPreset: preset,
      bitrateOverride: bitrate,
      startTime: start,
      endTime: end,
      playbackSpeed: speed,
      enableAudio: !mute,
      blur: blur,
      colorFilters: colorFilters,
      imageLayers: layers ?? const [],
      shouldOptimizeForNetworkUse: optimize,
    );

    await _runRenderToFile(outPath, data, label: 'Exporting');
  }

  Future<void> _runRenderToFile(
    String outPath,
    VideoRenderData data, {
    required String label,
  }) async {
    setState(() => _busy = label);
    final future = ProVideoEditor.instance.renderVideoToFile(outPath, data);
    if (!mounted) {
      future.then((_) {}, onError: (_) {});
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => _ExportProgressDialog(
        taskId: data.id,
        renderFuture: future,
        canCancel: _canCancelExport,
        onCancel: () => ProVideoEditor.instance.cancel(data.id),
      ),
    );
    if (mounted) setState(() => _busy = null);
    try {
      await future;
      if (mounted) _toast('Saved:\n$outPath');
    } on RenderCanceledException {
      if (mounted) _toast('Export cancelled.');
    } catch (e) {
      if (mounted) _toast('Export failed: $e');
    }
  }

  bool get _canCancelExport {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Video tools'),
        actions: [
          IconButton(
            tooltip: 'Pick video',
            onPressed: _pickVideo,
            icon: const Icon(Icons.video_file_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!proVideoEditorRenderExportSupported())
                Card(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  margin: const EdgeInsets.only(bottom: 16),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: Theme.of(context).colorScheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            kIsWeb
                                ? 'In the browser build, use Preview your clip to '
                                    'inspect a file. Full export, merge, waveform, '
                                    'and audio extraction need the Android or iOS app.'
                                : 'On Windows/Linux, use Preview your clip to check '
                                    'length, size, sound, and a filmstrip. '
                                    'Export, merge, waveform, and extract run on '
                                    'Android, iOS, or Mac with this editor.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSecondaryContainer,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (!_hasVideo) ...[
                Text(
                  'Start here',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  kIsWeb
                      ? 'Paste an https:// link to preview, then use the tools '
                          'that your platform supports.'
                      : 'Enter a local file path or https:// URL (no system '
                          'picker — use capture or host-provided paths).',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _pickVideo,
                  icon: const Icon(Icons.video_library_outlined),
                  label: kIsWeb
                      ? const Text('Open video from URL')
                      : const Text('Open video (path or URL)'),
                ),
                const SizedBox(height: 24),
              ] else ...[
                Text(
                  p.basename(_videoPathLabel(_video!)),
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (_meta != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${formatDurationHuman(_meta!.duration)} - '
                    '${formatFileSizeBytes(_meta!.fileSize)} - '
                    '${_meta!.resolution.width.toInt()}x${_meta!.resolution.height.toInt()}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Material(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: _openClipInsight,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.play_circle_outline,
                            size: 40,
                            color: Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Preview your clip',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'See length, size, sound, and a filmstrip - '
                                  'a preview before you edit.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimaryContainer,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'More tools',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
              ],
              _tile(
                icon: Icons.graphic_eq,
                title: 'Waveform',
                subtitle: !proVideoEditorRenderExportSupported()
                    ? 'Needs Android, iOS, or Mac'
                    : 'See loudness over time',
                onTap: _hasVideo && proVideoEditorRenderExportSupported()
                    ? _openWaveform
                    : null,
              ),
              _tile(
                icon: Icons.audio_file_outlined,
                title: 'Extract audio',
                subtitle: !proVideoEditorRenderExportSupported()
                    ? 'Needs Android, iOS, or Mac'
                    : 'Save AAC to a temp file',
                onTap: _hasVideo && proVideoEditorRenderExportSupported()
                    ? _extractAudio
                    : null,
              ),
              _tile(
                icon: Icons.merge_type_rounded,
                title: 'Merge videos',
                subtitle: !proVideoEditorRenderExportSupported()
                    ? 'Needs Android, iOS, or Mac'
                    : 'Join clips in order',
                onTap: proVideoEditorRenderExportSupported() ? _mergeVideos : null,
              ),
              _tile(
                icon: Icons.ios_share_rounded,
                title: 'Export',
                subtitle: !proVideoEditorRenderExportSupported()
                    ? 'Needs Android, iOS, or Mac'
                    : 'Trim, speed, filters, quality',
                onTap: _hasVideo && proVideoEditorRenderExportSupported()
                    ? _openExportSheet
                    : null,
              ),
            ],
          ),
          if (_busy != null)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        enabled: onTap != null,
        onTap: onTap,
      ),
    );
  }
}

class _ExportProgressDialog extends StatefulWidget {
  const _ExportProgressDialog({
    required this.taskId,
    required this.renderFuture,
    required this.canCancel,
    required this.onCancel,
  });

  final String taskId;
  final Future<void> renderFuture;
  final bool canCancel;
  final Future<void> Function() onCancel;

  @override
  State<_ExportProgressDialog> createState() => _ExportProgressDialogState();
}

class _ExportProgressDialogState extends State<_ExportProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.renderFuture.whenComplete(() {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exporting video'),
      content: StreamBuilder<ProgressModel>(
        stream: ProVideoEditor.instance.progressStreamById(widget.taskId),
        builder: (context, snap) {
          final v = snap.data?.progress;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (v != null) LinearProgressIndicator(value: v) else const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(v != null ? '${(v * 100).toStringAsFixed(0)}%' : 'Starting'),
            ],
          );
        },
      ),
      actions: [
        if (widget.canCancel)
          TextButton(
            onPressed: () => widget.onCancel(),
            child: const Text('Cancel'),
          ),
      ],
    );
  }
}

class _MinisWaveformPage extends StatefulWidget {
  const _MinisWaveformPage({required this.video});

  final EditorVideo video;

  @override
  State<_MinisWaveformPage> createState() => _MinisWaveformPageState();
}

class _MinisWaveformPageState extends State<_MinisWaveformPage> {
  var _streaming = false;

  @override
  Widget build(BuildContext context) {
    final config = WaveformConfigs(
      video: widget.video,
      resolution: WaveformResolution.medium,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Waveform'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _streaming = !_streaming),
            child: Text(_streaming ? 'Static' : 'Streaming'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Uses pro_video_editor waveform APIs (static or progressive streaming).',
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _streaming
                  ? AudioWaveform.streaming(
                      config: config,
                      style: WaveformStyle(
                        height: 120,
                        waveColor: Theme.of(context).colorScheme.primary,
                        backgroundColor:
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    )
                  : FutureBuilder<WaveformData>(
                      future: ProVideoEditor.instance.getWaveform(config),
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return Text('Error: ${snap.error}');
                        }
                        if (!snap.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        return AudioWaveform(
                          waveform: snap.data!,
                          style: WaveformStyle(
                            height: 120,
                            waveColor: Theme.of(context).colorScheme.primary,
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
