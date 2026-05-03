import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// Re-encodes to a broadly ExoPlayer-safe MP4 (H.264 + 720p) when the source
/// cannot be decoded in-preview or in [Trimmer].
///
/// Uses ProVideoEditor (FFmpeg) — reliable and memory-safe unlike
/// VideoCompress which OOMs on larger files.
///
/// Returns a new path, or `null` on failure. Callers should delete the returned
/// file when the user cancels, or if playback still fails.
Future<String?> minisTranscodeToH264ForDevicePlayback(
  String inputPath,
) async {
  final f = File(inputPath);
  if (!await f.exists()) return null;

  if (kIsWeb) return null;
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.macOS) {
    return null;
  }

  try {
    final dir = await getTemporaryDirectory();
    final outPath = p.join(
      dir.path,
      'minis_h264_${DateTime.now().microsecondsSinceEpoch}.mp4',
    );

    final data = VideoRenderData.withQualityPreset(
      videoSegments: [
        VideoSegment(video: EditorVideo.file(File(inputPath))),
      ],
      qualityPreset: VideoQualityPreset.p720High,
      outputFormat: VideoOutputFormat.mp4,
      enableAudio: true,
      transform: const ExportTransform(scaleX: 1.0, scaleY: 1.0),
    );

    await ProVideoEditor.instance.renderVideoToFile(outPath, data);

    final outFile = File(outPath);
    if (!await outFile.exists() || await outFile.length() < 1024) {
      return null;
    }
    return outPath;
  } catch (e, st) {
    debugPrint('minisH264Repair: failed for $inputPath: $e\n$st');
    return null;
  }
}
