import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/src/independent/minis_music_trim_math.dart';

void main() {
  const barTotal = 4.0;
  const boxW = 120.0;

  group('minisMusicTrimStartMsFromScrollLinear', () {
    test('maps across full range', () {
      expect(
        minisMusicTrimStartMsFromScrollLinear(
          scrollOffsetPx: 0,
          maxScrollPx: 280,
          maxStartMs: 60000,
        ),
        0,
      );
      expect(
        minisMusicTrimStartMsFromScrollLinear(
          scrollOffsetPx: 140,
          maxScrollPx: 280,
          maxStartMs: 60000,
        ),
        30000,
      );
      expect(
        minisMusicTrimStartMsFromScrollLinear(
          scrollOffsetPx: 280,
          maxScrollPx: 280,
          maxStartMs: 60000,
        ),
        60000,
      );
    });

    test('zero max scroll or start returns 0', () {
      expect(
        minisMusicTrimStartMsFromScrollLinear(
          scrollOffsetPx: 50,
          maxScrollPx: 0,
          maxStartMs: 5000,
        ),
        0,
      );
    });
  });

  group('minisMusicTrimScrollOffsetForStartMsLinear', () {
    test('endpoints round-trip exactly', () {
      const maxScroll = 280.0;
      const maxStart = 90000;
      for (final start in [0, 90000]) {
        final off = minisMusicTrimScrollOffsetForStartMsLinear(
          startMs: start,
          maxScrollPx: maxScroll,
          maxStartMs: maxStart,
        );
        final back = minisMusicTrimStartMsFromScrollLinear(
          scrollOffsetPx: off,
          maxScrollPx: maxScroll,
          maxStartMs: maxStart,
        );
        expect(back, start);
      }
    });

    test('midpoint round-trips within rounding', () {
      const maxScroll = 280.0;
      const maxStart = 90000;
      const start = 45000;
      final off = minisMusicTrimScrollOffsetForStartMsLinear(
        startMs: start,
        maxScrollPx: maxScroll,
        maxStartMs: maxStart,
      );
      final back = minisMusicTrimStartMsFromScrollLinear(
        scrollOffsetPx: off,
        maxScrollPx: maxScroll,
        maxStartMs: maxStart,
      );
      expect((back - start).abs(), lessThan(500));
    });
  });

  group('minisMusicTrimInnerTrackWidthPx', () {
    test('uses full bar row width when wider than frame', () {
      final inner = minisMusicTrimInnerTrackWidthPx(
        boxWidthPx: boxW,
        waveBarCount: 50,
        barTotalWidth: barTotal,
      );
      expect(inner, 50 * barTotal);
    });

    test('at least frame width when few bars', () {
      final inner = minisMusicTrimInnerTrackWidthPx(
        boxWidthPx: boxW,
        waveBarCount: 20,
        barTotalWidth: barTotal,
      );
      expect(inner, boxW);
    });
  });

  group('minisMusicTrimMaxScrollForViewport', () {
    test('symmetric padding matches sheet layout', () {
      const screenW = 400.0;
      const inner = 400.0;
      final maxS = minisMusicTrimMaxScrollForViewport(
        viewportWidthPx: screenW,
        boxWidthPx: boxW,
        innerTrackWidthPx: inner,
      );
      expect(maxS, inner - boxW);
    });
  });

  // Legacy second-based API (still exported for callers/tests of old behavior)
  group('minisMusicTrimStartMsFromScroll (legacy)', () {
    test('maps offset to second boundaries', () {
      expect(
        minisMusicTrimStartMsFromScroll(
          scrollOffsetPx: 0,
          barTotalWidth: barTotal,
          oneBarValue: 10,
          audioDurationMs: 120000,
          windowMs: 30000,
        ),
        0,
      );
    });
  });
}
