import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:loopit_minis/src/sys/paths.dart';

/// Waits until [path] exists and has non-trivial size (export may flush late).
Future<bool> waitUntilMinisVideoFileReady(
  String path, {
  int maxAttempts = 50,
  Duration interval = const Duration(milliseconds: 100),
  int minBytes = 1024,
}) async {
  for (var i = 0; i < maxAttempts; i++) {
    final f = File(path);
    if (await f.exists()) {
      try {
        final len = await f.length();
        if (len >= minBytes) {
          // Stable size — avoid opening the player while export is still flushing.
          await Future<void>.delayed(const Duration(milliseconds: 60));
          final len2 = await f.length();
          if (len2 == len) return true;
        }
      } catch (_) {}
    }
    await Future<void>.delayed(interval);
  }
  try {
    final f = File(path);
    final exists = await f.exists();
    final len = exists ? await f.length() : -1;
    debugPrint(
      'MINIS_MULTICLIP: gallery:ready: waitUntilMinisVideoFileReady FAILED after $maxAttempts tries '
      'exists=$exists len=$len path=${NativePaths.basename(path)}',
    );
  } catch (e) {
    debugPrint(
      'MINIS_MULTICLIP: gallery:ready: waitUntilMinisVideoFileReady FAILED path=$path err=$e',
    );
  }
  return false;
}

/// Copies the file into app temp so [VideoPlayer] / ExoPlayer can open it when
/// the original path (picker handoff, merge output, or shared storage) fails to decode.
Future<String?> minisCopyVideoToTempForPlayback(String sourcePath) async {
  final src = File(sourcePath);
  if (!await src.exists()) return null;
  try {
    final dirPath = await NativePaths.cacheDir();
    if (dirPath == null) return null;
    final base = NativePaths.basename(sourcePath);
    final safe = base.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final name =
        'minis_play_${DateTime.now().microsecondsSinceEpoch}_$safe';
    final dest = File(NativePaths.join([dirPath, name]));
    await src.copy(dest.path);
    return dest.path;
  } catch (_) {
    return null;
  }
}
