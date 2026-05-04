import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// User-chosen slice of an audio file for reel background / guide playback.
///
/// [path] must be a **readable filesystem path** that [audio_waveforms] and the
/// merge pipeline can open (e.g. materialized copy from the picker). The trim
/// sheet returns the path it successfully prepared for playback.
class MinisMusicSegment {
  const MinisMusicSegment({
    required this.path,
    required this.startMs,
    required this.endMs,
  }) : assert(startMs >= 0),
       assert(endMs >= startMs);

  final String path;
  final int startMs;
  final int endMs;

  int get windowMs => endMs - startMs;
}

/// Deletes all persisted music files from the `minis_music/` directory.
///
/// Call after a successful upload to prevent accumulation of stale copies.
/// Safe to call even if the directory does not exist or is already empty.
Future<void> cleanUpMinisMusicFiles() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final musicDir = Directory(p.join(dir.path, 'minis_music'));
    if (await musicDir.exists()) {
      await musicDir.delete(recursive: true);
      debugPrint('[minis_music] cleaned up persisted music files');
    }
  } catch (e) {
    debugPrint('[minis_music] cleanup failed (non-fatal): $e');
  }
}

/// [audio_waveforms] player + trim UI are implemented for Android and iOS only.
bool minisAudioWaveformsTrimSupported() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
