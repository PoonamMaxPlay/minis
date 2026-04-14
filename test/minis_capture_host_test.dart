import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/src/minis_capture_host.dart';

void main() {
  tearDown(() {
    MinisCaptureHost.resetForTest();
  });

  testWidgets('openCapture throws when not registered', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    MinisCaptureHost.openCapture<void>();
                  },
                  child: const Text('go'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('go'));
    expect(tester.takeException(), isA<StateError>());
  });
}
