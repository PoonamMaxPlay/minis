import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/loopit_minis.dart';

void main() {
  testWidgets('independent capture shows controls after fake init', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MinisIndependentCaptureScreen(
          permissionPolicy: MinisCapturePermissionPolicy.assumeGranted,
          engine: _FakeEngine(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Flip'), findsOneWidget);
  });

  testWidgets(
      'narrow layout: bottom bar fits without overflow errors',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MinisIndependentCaptureScreen(
          permissionPolicy: MinisCapturePermissionPolicy.assumeGranted,
          engine: _FakeEngine(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });
}

class _FakeEngine extends MinisCameraEnginePort {
  @override
  bool isInitialized = false;

  @override
  Future<void> dispose() async {}

  @override
  Future<void> initialize() async {
    isInitialized = true;
  }

  @override
  Widget buildPreview(BuildContext context) =>
      const ColoredBox(color: Color(0xFF222222));

  @override
  Future<void> startRecording({String? preferredOutputPath}) async {}

  @override
  Future<String?> stopRecording() async => null;

  @override
  Future<String?> takePicture() async => null;

  @override
  Future<void> switchCamera() async {}

  @override
  bool get isTorchOn => false;

  @override
  Future<void> setTorchEnabled(bool enabled) async {}

  @override
  Future<void> setRecordWithAudio(bool enabled) async {}

  @override
  Future<double> getMinZoomLevel() async => 1.0;

  @override
  Future<double> getMaxZoomLevel() async => 1.0;

  @override
  Future<void> setZoomLevel(double zoom) async {}
}
