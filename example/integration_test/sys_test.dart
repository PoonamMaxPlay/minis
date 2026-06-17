import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loopit_minis/loopit_minis.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('paths round-trip', (tester) async {
    final cache = await NativePaths.cacheDir();
    expect(cache, isNotNull);
    expect(cache!.isNotEmpty, isTrue);
    final docs = await NativePaths.documentsDir();
    expect(docs, isNotNull);
    final joined = NativePaths.join([cache, 'sub', 'file.txt']);
    expect(joined.endsWith('file.txt'), isTrue);
    expect(NativePaths.extension('foo.bar/baz.mp4'), '.mp4');
    expect(NativePaths.basename('a/b/c.dat'), 'c.dat');
  });

  testWidgets('permission check returns one of the four states', (tester) async {
    final s = await NativePermissions.check('camera');
    expect(
      [
        PermissionStatus.granted,
        PermissionStatus.denied,
        PermissionStatus.permDenied,
        PermissionStatus.restricted,
      ],
      contains(s),
    );
  });

  testWidgets('device info populated', (tester) async {
    final info = await NativeDeviceInfo.info();
    expect(info.os.isNotEmpty, isTrue);
    expect(info.osVersion.isNotEmpty, isTrue);
  });

  testWidgets('wakelock toggle does not throw', (tester) async {
    await NativeWakelock.enable();
    await NativeWakelock.disable();
  });

  testWidgets('player create→play→seek→pause→dispose', (tester) async {
    final sampleAsset = File('integration_test/test_assets/sample.mp4');
    if (!sampleAsset.existsSync()) {
      return; // sample asset optional — skip in CI without it.
    }
    final c = NativeVideoPlayerController();
    await c.open(path: sampleAsset.path, autoplay: false);
    expect(c.playerId, isNotNull);
    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await c.seek(1000);
    await c.pause();
    await c.dispose();
  });
}
