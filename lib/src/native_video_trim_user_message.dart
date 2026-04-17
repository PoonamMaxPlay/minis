import 'dart:developer' as developer;

import 'package:flutter/services.dart';

/// Developer / Crashlytics-friendly line: full [PlatformException] fields and optional context.
/// Does not throw; safe to call before showing [messageForVideoTrimFailure].
void logVideoTrimDiagnostic(
  Object error, {
  StackTrace? stackTrace,
  String context = '',
  Map<String, Object?>? extra,
}) {
  final buf = StringBuffer();
  if (context.isNotEmpty) {
    buf.writeln('context: $context');
  }
  if (error is PlatformException) {
    buf.writeln('PlatformException');
    buf.writeln('  code: ${error.code}');
    buf.writeln('  message: ${error.message}');
    buf.writeln('  details: ${error.details}');
    final st = error.stacktrace;
    if (st != null && st.isNotEmpty) {
      buf.writeln('  stacktrace: $st');
    }
  } else {
    buf.writeln('errorType: ${error.runtimeType}');
    buf.writeln('error: $error');
  }
  if (extra != null && extra.isNotEmpty) {
    buf.writeln('extra:');
    extra.forEach((k, v) => buf.writeln('  $k: $v'));
  }
  buf.writeln('userFacing: ${messageForVideoTrimFailure(error)}');
  developer.log(
    buf.toString().trimRight(),
    name: 'loopit_video_trim',
    error: error is Exception || error is Error ? error : null,
    stackTrace: stackTrace,
  );
}

/// Native export completed but returned no file path (plugin callback).
void logVideoTrimMissingOutputDiagnostic({
  String context = '',
  Map<String, Object?>? extra,
}) {
  final buf = StringBuffer()
    ..writeln('saveTrimmedVideo onSave: null or empty outputPath');
  if (context.isNotEmpty) {
    buf.writeln('context: $context');
  }
  if (extra != null && extra.isNotEmpty) {
    buf.writeln('extra:');
    extra.forEach((k, v) => buf.writeln('  $k: $v'));
  }
  developer.log(buf.toString().trimRight(), name: 'loopit_video_trim');
}

/// Maps errors from [flutter_native_video_trimmer] (used by [video_trimmer] export)
/// and related failures into short, user-facing copy (never raw [PlatformException] text).
String messageForVideoTrimFailure(Object error) {
  if (error is PlatformException) {
    return _messageForPlatformException(error);
  }
  final text = error.toString();
  if (text.contains('PlatformException')) {
    return _genericTrimAdvice();
  }
  return _genericTrimAdvice();
}

String _messageForPlatformException(PlatformException e) {
  final code = e.code;
  final raw = e.message;
  final msg = (raw != null && raw.isNotEmpty && raw != 'null') ? raw : '';

  switch (code) {
    case 'INVALID_ARGUMENTS':
      return 'Trim could not start. Close this screen and try again.';
    case 'INVALID_TIME_RANGE':
      return 'Move the trim handles so the selection stays inside the video.';
    case 'TRIM_ERROR':
      return _interpretTrimErrorMessage(msg);
    default:
      if (msg.isNotEmpty) {
        return _interpretTrimErrorMessage(msg);
      }
      return _genericTrimAdvice();
  }
}

String _interpretTrimErrorMessage(String message) {
  final m = message.toLowerCase();

  if (m.contains('not found') || m.contains('file not found')) {
    return 'The video file is missing. Try recording or choosing the clip again.';
  }
  if (m.contains('no video') && m.contains('load')) {
    return 'The video did not load. Try again in a moment.';
  }
  if (m.contains('unsupported') ||
      m.contains('format is not supported') ||
      m.contains('compatible')) {
    return 'This video format cannot be trimmed on this device. Try another clip or re-export as MP4.';
  }
  if (m.contains('invalid time') ||
      m.contains('time range') ||
      m.contains('duration')) {
    return 'Adjust the trim selection to fit inside the video length.';
  }
  if (m.contains('cancelled')) {
    return 'Trim was cancelled.';
  }
  if (m.contains('space') ||
      m.contains('storage') ||
      m.contains('no space')) {
    return 'Not enough storage to save the trimmed video. Free some space and try again.';
  }
  if (m.contains('permission') || m.contains('denied')) {
    return 'Storage permission is needed to save the trimmed video.';
  }

  // Short native messages can be shown as-is (e.g. iOS [VideoError] strings).
  if (message.length <= 120 && !message.contains('Exception')) {
    return message;
  }

  return _genericTrimAdvice();
}

String _genericTrimAdvice() {
  return 'Could not trim this video. Try again, use a shorter selection, or pick another clip.';
}

/// When native export returns no path (save callback with null / empty).
String messageForVideoTrimMissingOutput() {
  return 'The trimmed video could not be saved. Try again or pick another clip.';
}
