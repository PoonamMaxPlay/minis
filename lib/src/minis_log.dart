import 'package:flutter/foundation.dart';

/// Signature of a host-installed log sink. [error]/[stackTrace] are present
/// when the message comes from a caught exception.
typedef MinisLogHandler = void Function(
  String message, {
  Object? error,
  StackTrace? stackTrace,
});

/// Pluggable logging hook for the minis package.
///
/// The package itself stays free of app dependencies: by default messages go
/// to [debugPrint]. The host app installs a handler (e.g. forwarding to its
/// logger + Crashlytics non-fatals) so capture/merge failures stop
/// disappearing silently in production builds.
class MinisLog {
  MinisLog._();

  /// Host-installed sink. Null → [debugPrint] fallback.
  static MinisLogHandler? handler;

  /// Report a recoverable-but-noteworthy failure (the flow continued, but the
  /// user-visible result may be degraded — e.g. silent audio, missing thumb).
  static void w(String message, [Object? error, StackTrace? stackTrace]) {
    final h = handler;
    if (h != null) {
      try {
        h(message, error: error, stackTrace: stackTrace);
        return;
      } catch (_) {/* a broken sink must never break the capture flow */}
    }
    debugPrint('minis: $message${error == null ? '' : ' — $error'}');
  }
}
