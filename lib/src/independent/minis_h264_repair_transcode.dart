import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:loopit_minis/src/sys/paths.dart';

import 'package:loopit_minis/src/videdit/videdit_engine.dart';
import 'package:loopit_minis/src/videdit/videdit_types.dart';

/// Re-encodes to a broadly playable MP4 (H.264 ~720p) when the source cannot
/// be decoded directly by ExoPlayer / AVPlayer. Delegates to the native
/// VidEdit engine. Returns a new path, or `null` when the engine is not
/// available in this build or the operation fails.
///
/// Callers should delete the returned file when the user cancels, or if
/// playback still fails.
Future<String?> minisTranscodeToH264ForDevicePlayback(
  String inputPath,
) async {
  final f = File(inputPath);
  if (!await f.exists()) return null;

  final engine = MinisVidEdit.instance;
  if (!engine.isPlatformEligible) return null;
  if (!await engine.isAvailable()) return null;

  try {
    final dirPath = await NativePaths.cacheDir();
    if (dirPath == null) return null;
    final outPath = NativePaths.join([
      dirPath,
      'minis_repair_${DateTime.now().microsecondsSinceEpoch}.mp4',
    ]);
    final result = await engine.repair(
      inputPath: inputPath,
      outputPath: outPath,
      targetHeight: 720,
    );
    if (result == null || result.isEmpty) return null;
    if (!await File(result).exists()) return null;
    return result;
  } on VidEditUnsupportedError {
    return null;
  } on VidEditCancelled {
    return null;
  } catch (e, st) {
    debugPrint('minisH264Repair: failed for $inputPath: $e\n$st');
    return null;
  }
}
