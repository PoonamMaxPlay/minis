import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// Builds the full-screen **Minis capture** UI (multi-clip reels camera).
///
/// The implementation cannot live entirely inside [loopit_minis] today without
/// either (a) a circular dependency on the host app (`shortzz`), or (b) moving
/// [CameraScreenController], [ReelsCameraController], and the camera engine
/// into this package or a shared `loopit_camera` module. The host registers
/// the real widget at startup; see [register].
typedef MinisCaptureWidgetBuilder = Widget Function();

/// Host-provided music selection for Minis.
///
/// [path] must point to a readable local file path.
class MinisHostMusicSelection {
  const MinisHostMusicSelection({
    required this.path,
    required this.startMs,
    required this.endMs,
  });

  final String path;
  final int startMs;
  final int endMs;
}

/// Lets host apps provide a music picker UX (for example, LoopIt's MusicSheet).
///
/// Return null when the user cancels.
typedef MinisMusicPicker = Future<MinisHostMusicSelection?> Function({
  MinisHostMusicSelection? currentSelection,
  required int sessionCapMs,
});

/// Entry point for **Minis** from the create sheet (and any other host affordance).
///
/// Call [register] once from the app (e.g. in `main`) before using [openCapture].
abstract final class MinisCaptureHost {
  static MinisCaptureWidgetBuilder? _builder;
  static MinisMusicPicker? _musicPicker;

  /// Host supplies [LoopItCameraScreen(mode: reels)] (or equivalent).
  static void register(MinisCaptureWidgetBuilder builder) {
    _builder = builder;
  }

  /// Host supplies a music picker used by Minis "Sounds" action.
  static void registerMusicPicker(MinisMusicPicker picker) {
    _musicPicker = picker;
  }

  /// Clears registration (mainly for tests).
  static void resetForTest() {
    _builder = null;
    _musicPicker = null;
  }

  /// Whether [register] has been called.
  static bool get isRegistered => _builder != null;

  /// Whether [registerMusicPicker] has been called.
  static bool get isMusicPickerRegistered => _musicPicker != null;

  /// Pushes the Minis capture route using GetX ([Get.to]).
  static Future<T?>? openCapture<T>() {
    final b = _builder;
    if (b == null) {
      throw StateError(
        'MinisCaptureHost.register(...) was not called. '
        'Register from the LoopIt app (see minis_capture_registration.dart).',
      );
    }
    return Get.to<T>(() => b());
  }

  /// Opens host music picker if registered.
  static Future<MinisHostMusicSelection?> pickMusic({
    MinisHostMusicSelection? currentSelection,
    required int sessionCapMs,
  }) async {
    final picker = _musicPicker;
    if (picker == null) return null;
    return picker(
      currentSelection: currentSelection,
      sessionCapMs: sessionCapMs,
    );
  }
}
