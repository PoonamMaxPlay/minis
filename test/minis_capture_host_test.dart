import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/src/minis_capture_host.dart';

void main() {
  tearDown(() {
    MinisCaptureHost.resetForTest();
  });

  testWidgets('openCapture returns null when not registered (no throw)', (tester) async {
    Object? result = Object();
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await MinisCaptureHost.openCapture<dynamic>();
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
    // Snackbar auto-dismiss timer (3s) + exit animation must finish before teardown.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
