import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/src/independent/minis_camera_performance.dart';

void main() {
  test('resolutionPresetForMinisMode maps tiers', () {
    expect(
      resolutionPresetForMinisMode(MinisCameraPerformanceMode.performance),
      ResolutionPreset.medium,
    );
    expect(
      resolutionPresetForMinisMode(MinisCameraPerformanceMode.balanced),
      ResolutionPreset.high,
    );
    expect(
      resolutionPresetForMinisMode(MinisCameraPerformanceMode.quality),
      ResolutionPreset.veryHigh,
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
      minisPresetFallbackChain(ResolutionPreset.high),
      <ResolutionPreset>[
        ResolutionPreset.high,
        ResolutionPreset.medium,
        ResolutionPreset.low,
      ],
    );
    expect(
      minisPresetFallbackChain(ResolutionPreset.veryHigh),
      equals(minisCameraResolutionRungs),
    );
  });
}