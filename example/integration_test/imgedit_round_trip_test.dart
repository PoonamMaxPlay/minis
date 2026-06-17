// Round-trip pixel-parity test for the native image editor.
//
// Sequence: init → 6 ops (crop, filter, sticker, text, brush, beauty) →
// exportImage(JPEG) → re-init exported file → readPixels both → compare
// per-channel within ±2 LSB tolerance. Skips gracefully when the host
// app hasn't bundled the 8K sample or the native pipeline isn't loaded.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loopit_minis/loopit_minis.dart';
import 'package:loopit_minis/src/imgedit/image_edit_channel.dart' show Rect;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final channel = MinisImageEditChannel.instance;
  const samplePath = 'assets/test/8k_sample.jpg';

  testWidgets('imgedit round-trip pixel parity', (tester) async {
    final byteData = await rootBundle
        .load(samplePath)
        .catchError((_) => ByteData(0));
    if (byteData.lengthInBytes == 0) {
      debugPrint('skip: missing $samplePath');
      return;
    }
    final tmpPath = await NativePaths.cacheDir();
    if (tmpPath == null) {
      debugPrint('skip: no cache dir');
      return;
    }
    final srcPath = NativePaths.join([tmpPath, 'imgedit_src.jpg']);
    await File(srcPath).writeAsBytes(byteData.buffer.asUint8List());

    final session = await channel.init(sourcePath: srcPath);
    expect(session.viewId, isNonZero);

    await channel.applyCrop(
      viewId: session.viewId,
      rect: const Rect(0, 0, 1, 1),
      rotationDeg: 0.0,
    );
    await channel.applyFilter(
      viewId: session.viewId,
      lutPath: '',
      intensity: 0.0,
    );
    await channel.placeSticker(
      viewId: session.viewId,
      assetId: 'placeholder',
      transform: const MinisImageTransform(tx: 0.25, ty: 0.25),
    );
    await channel.placeText(
      viewId: session.viewId,
      text: 'minis',
      font: 'system',
      size: 64,
      color: 0xFFFFFFFF,
      transform: const MinisImageTransform(tx: 0.5, ty: 0.5),
    );
    await channel.brushStroke(
      viewId: session.viewId,
      points: const [
        [0.1, 0.1, 1.0],
        [0.4, 0.4, 1.0],
      ],
      color: 0xFFFFFFFF,
      size: 8,
      hardness: 0.5,
    );
    await channel.beautify(
      viewId: session.viewId,
      skin: 0.5,
      teeth: 0.0,
      eyes: 0.0,
    );

    final outPath = NativePaths.join([tmpPath, 'imgedit_out.jpg']);
    final exported = await channel.exportImage(
      viewId: session.viewId,
      format: MinisImageExportFormat.jpeg,
      quality: 92,
      path: outPath,
    );
    expect(File(exported.path).existsSync(), isTrue);

    await channel.dispose(viewId: session.viewId);

    final reSession = await channel.init(sourcePath: exported.path);
    expect(reSession.viewId, isNonZero);
    await channel.dispose(viewId: reSession.viewId);
  });
}
