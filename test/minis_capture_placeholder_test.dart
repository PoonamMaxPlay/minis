import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/src/minis_capture_placeholder.dart';

void main() {
  testWidgets('MinisCapturePlaceholder shows title', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MinisCapturePlaceholder(),
      ),
    );
    expect(find.textContaining('Video capture'), findsOneWidget);
  });
}
