import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

void main() {
  testWidgets('Minis example shell builds (fake engine, no hardware)',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: MinisSession(
          child: MinisIndependentCaptureScreen(
            permissionPolicy: MinisCapturePermissionPolicy.assumeGranted,
            engine: _FakeEngine(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Flip'), findsOneWidget);
  });
}

class _FakeEngine implements MinisCameraEnginePort {
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
