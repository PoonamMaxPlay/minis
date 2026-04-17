import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Builds the full-screen **Minis capture** UI (multi-clip reels camera).
///
/// The implementation cannot live entirely inside [loopit_minis] today without
/// either (a) a circular dependency on the host app (`shortzz`), or (b) moving
/// [CameraScreenController], [ReelsCameraController], and the camera engine
/// into this package or a shared `loopit_camera` module. The host registers
/// the real widget at startup; see [register].
///
/// [videoOnly] — when true (Minis/reel product entry), the capture surface should
/// not offer photo capture or still imports from the media library.
typedef MinisCaptureWidgetBuilder = Widget Function({bool videoOnly});

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
  static Completer<Object?>? _captureResultCompleter;

  /// Blocking loader inserted before the capture route pops — avoids a flash of
  /// dashboard/home until the host runs [normalize] / [Get.to].
  static OverlayEntry? _handoffOverlayEntry;

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
    _captureResultCompleter = null;
    _handoffOverlayEntry = null;
  }

  /// Whether [register] has been called.
  static bool get isRegistered => _builder != null;

  /// Whether [registerMusicPicker] has been called.
  static bool get isMusicPickerRegistered => _musicPicker != null;

  static void _snack(String message) {
    try {
      Get.snackbar(
        'Minis',
        message,
        snackPosition: SnackPosition.TOP,
        duration: const Duration(seconds: 3),
        backgroundColor: const Color(0xE61C1C1E),
        colorText: Colors.white,
        margin: const EdgeInsets.all(16),
        borderRadius: 10,
      );
    } catch (_) {}
  }

  /// Pushes the Minis capture route on root Navigator.
  ///
  /// Set [videoOnly] for reel / “Minis” flows where still photos must not be
  /// captured or imported; leave false for story and feed camera pickers.
  ///
  /// Returns `null` if Minis is not registered, or a capture session is
  /// already open (shows a short message when [Get] is available).
  static Future<T?> openCapture<T>({
    BuildContext? context,
    bool videoOnly = false,
  }) {
    final b = _builder;
    if (b == null) {
      _snack(
        'Camera is not available in this build. Update the app or reinstall.',
      );
      return Future<T?>.value(null);
    }
    if (_captureResultCompleter != null &&
        !(_captureResultCompleter?.isCompleted ?? true)) {
      _snack('Minis is already open. Close it first, then try again.');
      return Future<T?>.value(null);
    }
    final completer = Completer<Object?>();
    _captureResultCompleter = completer;

    final ctx = context ?? Get.context ?? Get.key.currentContext;
    Future<T?> routeFuture;
    if (ctx != null) {
      routeFuture = Navigator.of(ctx, rootNavigator: true).push<T>(
        MaterialPageRoute<T>(
          builder: (_) => b(videoOnly: videoOnly),
          fullscreenDialog: true,
        ),
      );
    } else {
      routeFuture = Get.to<T>(() => b(videoOnly: videoOnly)) ??
          Future<T?>.value(null);
    }

    return routeFuture.then((routeResult) {
      final completed = completer.isCompleted;
      final hostResult = completed ? completer.future : Future<Object?>.value(routeResult);
      return hostResult.then((value) => value as T?);
    }).whenComplete(() {
      if (identical(_captureResultCompleter, completer)) {
        _captureResultCompleter = null;
      }
    });
  }

  /// True when [completeCaptureResult] inserted the handoff overlay (not yet
  /// [dismissHandoffOverlay]).
  static bool get hasHandoffOverlay => _handoffOverlayEntry != null;

  static void _insertHandoffOverlay() {
    if (_handoffOverlayEntry != null) return;
    final ctx = Get.overlayContext ?? Get.key.currentContext;
    if (ctx == null) return;
    final overlay = Overlay.maybeOf(ctx);
    if (overlay == null) return;

    _handoffOverlayEntry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: Material(
          color: Colors.black.withValues(alpha: 0.65),
          child: const Center(
            child: SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_handoffOverlayEntry!);
  }

  /// Removes the loader shown during capture handoff. Safe to call when none
  /// was inserted.
  static void dismissHandoffOverlay() {
    final e = _handoffOverlayEntry;
    if (e == null) return;
    _handoffOverlayEntry = null;
    e.remove();
  }

  /// Completes the active capture call with a definitive result.
  static void completeCaptureResult(Object? result) {
    _insertHandoffOverlay();
    final c = _captureResultCompleter;
    if (c != null && !c.isCompleted) {
      c.complete(result);
    }
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
