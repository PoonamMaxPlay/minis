import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/src/independent/minis_camera_performance.dart';

void main() {
  test('resolutionPresetForMinisMode maps tiers', () {
    expect(
      resolutionPresetForMinisMode(MinisCameraPerformanceMode.performance),
      MinisResolutionPreset.medium,
    );
    expect(
      resolutionPresetForMinisMode(MinisCameraPerformanceMode.balanced),
      MinisResolutionPreset.high,
    );
    expect(
      resolutionPresetForMinisMode(MinisCameraPerformanceMode.quality),
      MinisResolutionPreset.veryHigh,
    );
  });

  test('resolutionPresetForMinisMode rejects auto', () {
    expect(
      () => resolutionPresetForMinisMode(MinisCameraPerformanceMode.auto),
      throwsArgumentError,
    );
  });

  test('minisPresetFallbackChain starts at primary and runs downward', () {
    expect(
      minisPresetFallbackChain(MinisResolutionPreset.high),
      <MinisResolutionPreset>[
        MinisResolutionPreset.high,
        MinisResolutionPreset.medium,
        MinisResolutionPreset.low,
      ],
    );
    expect(
      minisPresetFallbackChain(MinisResolutionPreset.veryHigh),
      equals(minisCameraResolutionRungs),
    );
  });

  test('minisQualityTier maps to native quality tier ints', () {
    expect(minisQualityTier(MinisResolutionPreset.low), 0);
    expect(minisQualityTier(MinisResolutionPreset.medium), 0);
    expect(minisQualityTier(MinisResolutionPreset.high), 1);
    expect(minisQualityTier(MinisResolutionPreset.veryHigh), 2);
    expect(minisQualityTier(MinisResolutionPreset.ultraHigh), 3);
    expect(minisQualityTier(MinisResolutionPreset.max), 4);
  });
}
