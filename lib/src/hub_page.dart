/// Minis video hub — placeholder while video tools rebuild on a native
/// engine (improvement3.md). The pro_video_editor / video_thumbnail demo
/// surface that previously lived here was removed when those packages were
/// retired.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 1×1 PNG used as the starting canvas when creating an overlay (no separate
/// image-picker dependency). Kept here so existing overlay flows that import
/// from `loopit_minis/src/hub_page.dart` continue to compile.
final Uint8List kMinisBlankPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

String formatDurationHuman(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m}m ${s}s';
  if (m > 0) return '${m}m ${s}s';
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

/// Phase 1 capability shim. The previous hub used [pro_video_editor] for
/// thumbnails / metadata; both are off until the native engine ships.
bool proVideoEditorThumbnailsSupported() => false;
bool proVideoEditorRenderExportSupported() => false;

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

  /// Optional file path. Unused in Phase 1; kept for API compatibility.
  final String? initialVideoPath;

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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.movie_outlined, size: 64),
            const SizedBox(height: 16),
            Text(
              'Video tools are rebuilding on a native engine',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              kIsWeb
                  ? 'Not available on web.'
                  : 'Trim, merge, filters, captions and export return in the '
                      'next update.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.maybePop(context),
              child: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }
}
