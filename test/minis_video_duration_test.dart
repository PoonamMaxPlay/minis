import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/src/independent/minis_video_duration.dart';

void main() {
  group('minisFormatClipDurationLabel', () {
    test('formats mm:ss for typical clips', () {
      expect(minisFormatClipDurationLabel(0), '0:00');
      expect(minisFormatClipDurationLabel(1), '0:01');
      expect(minisFormatClipDurationLabel(400), '0:01');
      expect(minisFormatClipDurationLabel(500), '0:01');
      expect(minisFormatClipDurationLabel(5000), '0:05');
      expect(minisFormatClipDurationLabel(65000), '1:05');
      expect(minisFormatClipDurationLabel(125500), '2:06');
    });
  });

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

    test('ignores garbage probe under 500ms when reported is multi-second', () {
      expect(minisCoalesceClipDurationMs(30000, 10), 30000);
      expect(minisCoalesceClipDurationMs(5000, 100), 5000);
    });

    test('trusts long probe when reported is sub-500ms glitch', () {
      expect(minisCoalesceClipDurationMs(10, 30000), 30000);
      expect(minisCoalesceClipDurationMs(100, 25000), 25000);
    });
  });
}
