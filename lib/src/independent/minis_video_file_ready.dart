import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  return false;
}

/// Copies the file into app temp so [VideoPlayer] / ExoPlayer can open it when
/// the original path (picker handoff, merge output, or shared storage) fails to decode.
Future<String?> minisCopyVideoToTempForPlayback(String sourcePath) async {
  final src = File(sourcePath);
  if (!await src.exists()) return null;
  try {
    final dir = await getTemporaryDirectory();
    final base = p.basename(sourcePath);
    final safe = base.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final name =
        'minis_play_${DateTime.now().microsecondsSinceEpoch}_$safe';
    final dest = File(p.join(dir.path, name));
    await src.copy(dest.path);
    return dest.path;
  } catch (_) {
    return null;
  }
}
