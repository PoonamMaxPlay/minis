import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists a capture (photo or video) into app documents for the standalone
/// example (no host app).
final class MinisExampleSave {
  MinisExampleSave._();

  static Future<String?> copyIntoLibrary(String sourcePath) async {
    final src = File(sourcePath);
    if (!await src.exists()) return null;
    final dir = await getApplicationDocumentsDirectory();
    final sub = Directory(p.join(dir.path, 'minis_captures'));
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    final ext = p.extension(sourcePath).isEmpty ? '' : p.extension(sourcePath);
    final name = 'capture_${DateTime.now().millisecondsSinceEpoch}$ext';
    final dest = File(p.join(sub.path, name));
    await src.copy(dest.path);
    return dest.path;
  }

  static Future<void> saveAndNotify(String sourcePath) async {
    try {
      final saved = await copyIntoLibrary(sourcePath);
      if (saved == null) {
        Get.snackbar('Save failed', 'Source file missing.');
        return;
      }
      Get.snackbar(
        'Saved to app storage',
        saved,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 4),
      );
    } catch (e) {
      Get.snackbar('Save failed', '$e');
    }
  }
}
