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

/// Entry point for **Minis** from the create sheet (and any other host affordance).
///
/// Call [register] once from the app (e.g. in `main`) before using [openCapture].
abstract final class MinisCaptureHost {
  static MinisCaptureWidgetBuilder? _builder;

  /// Host supplies [LoopItCameraScreen(mode: reels)] (or equivalent).
  static void register(MinisCaptureWidgetBuilder builder) {
    _builder = builder;
  }

  /// Clears registration (mainly for tests).
  static void resetForTest() {
    _builder = null;
  }

  /// Whether [register] has been called.
  static bool get isRegistered => _builder != null;

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
}
