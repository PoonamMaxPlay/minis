import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_compress/video_compress.dart';

/// Re-encodes to a broadly ExoPlayer-safe MP4 (typically H.264 + ~720p) when
/// the source cannot be decoded in-preview or in [Trimmer], same family as
/// LoopIt reel upload re-encode.
///
/// Returns a new path, or `null` on failure. Callers should delete the returned
/// file when the user cancels, or if playback still fails.
Future<String?> minisTranscodeToH264ForDevicePlayback(
  String inputPath,
) async {
  final f = File(inputPath);
  if (!await f.exists()) return null;
  try {
    final out = await VideoCompress.compressVideo(
      inputPath,
      quality: VideoQuality.Res1280x720Quality,
      deleteOrigin: false,
      includeAudio: true,
    );
    final outPath = out?.path ?? out?.file?.path;
    if (outPath == null || outPath.isEmpty) return null;
    final outFile = File(outPath);
    if (!await outFile.exists()) return null;
    return outPath;
  } catch (e, st) {
    debugPrint('minisH264Repair: failed for $inputPath: $e\n$st');
    return null;
  }
}
