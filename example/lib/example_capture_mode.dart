import 'package:shared_preferences/shared_preferences.dart';

/// Capture surface the example launches into: mirrors LoopIt's
/// PostOptionsSheet rows (`PublishType.feed/story/reels`).
enum ExampleCaptureMode {
  story,
  feed,
  reel;

  String get label => switch (this) {
        ExampleCaptureMode.story => 'Story',
        ExampleCaptureMode.feed => 'Feed',
        ExampleCaptureMode.reel => 'Reel',
      };

  /// Reels camera maps to videoOnly=true (LoopIt: PublishType.reels →
  /// `openMinisReelCaptureAndCompose` calls `openCapture(videoOnly: true)`).
  bool get videoOnly => this == ExampleCaptureMode.reel;
}

/// SharedPreferences-backed persistence for the active capture mode.
final class ExampleCaptureModeStore {
  ExampleCaptureModeStore._();

  static const String _key = 'minis_example_capture_mode';
  static const ExampleCaptureMode _default = ExampleCaptureMode.reel;

  static Future<ExampleCaptureMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return _default;
    for (final m in ExampleCaptureMode.values) {
      if (m.name == raw) return m;
    }
    return _default;
  }

  static Future<void> save(ExampleCaptureMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
