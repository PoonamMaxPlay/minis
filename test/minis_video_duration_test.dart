import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/src/independent/minis_video_duration.dart';

void main() {
  group('minisCoalesceClipDurationMs', () {
    test('trusts reported when probe is suspiciously short', () {
      expect(
        minisCoalesceClipDurationMs(10000, 1000),
        10000,
      );
    });

    test('uses probed when it matches reported scale', () {
      expect(
        minisCoalesceClipDurationMs(10000, 9950),
        10000,
      );
    });

    test('uses larger of trim span vs probe when probe catches up', () {
      expect(
        minisCoalesceClipDurationMs(5000, 4800),
        5000,
      );
    });

    test('falls back to reported when probe is zero', () {
      expect(minisCoalesceClipDurationMs(3200, 0), 3200);
    });
  });
}
