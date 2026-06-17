import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:retrytech_plugin/retrytech_plugin.dart';

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

    final result = await RetrytechPlugin.shared.transcodeToH264(
      inputPath: inputPath,
      outputPath: outPath,
    );
    if (result.isEmpty) return null;

    final outFile = File(result);
    if (!await outFile.exists() || await outFile.length() < 1024) {
      return null;
    }
    return result;
  } catch (e, st) {
    debugPrint('minisH264Repair: failed for $inputPath: $e\n$st');
    return null;
  }
}
