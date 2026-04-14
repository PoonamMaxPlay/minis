import 'dart:io';

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
        if (len >= minBytes) return true;
      } catch (_) {}
    }
    await Future<void>.delayed(interval);
  }
  return false;
}
