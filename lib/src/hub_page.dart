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

/// Placeholder hub entry — keeps the existing call site
/// [MinisVideoHubPage.open] working without dragging back the removed
/// editor packages.
class MinisVideoHubPage extends StatelessWidget {
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
      appBar: AppBar(title: const Text('Video tools')),
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
