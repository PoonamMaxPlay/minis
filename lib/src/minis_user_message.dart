import 'package:flutter/services.dart';

/// User-facing line when the device cannot decode or play the media file.
String _playbackRecoveryMessage() =>
    'This video could not be played on this device. '
    'Try another clip or re-export as MP4 (H.264).';

/// True when [s] looks like a native decoder / ExoPlayer / MediaCodec dump.
/// Used by [minisUserFriendlyException] and trim/export messaging.
bool _looksLikeTechnicalPlaybackText(String s) {
  final t = s.toLowerCase();
  return t.contains('videoerror') ||
      t.contains('video player had error') ||
      t.contains('exoplayback') ||
      t.contains('exoplayer') ||
      t.contains('mediacodec') ||
      t.contains('androidx.media3') ||
      t.contains('decoder failed') ||
      t.contains('format(') ||
      t.contains('format_supported') ||
      t.contains('platformexception') ||
      t.contains('colorinfo(') ||
      t.contains('exoplaybackexception');
}

/// Same heuristic as playback errors; used for native trim / export paths.
bool minisLooksLikeDecoderOrPlaybackDump(String s) =>
    _looksLikeTechnicalPlaybackText(s);

/// Short, user-facing copy for capture / gallery / playback failures (never raw exceptions).
String minisUserFriendlyException(Object error, {String context = ''}) {
  if (error is MissingPluginException) {
    return 'Video tools are not available in this build. '
        'Run on a device with a full release build, or reinstall the app.';
  }
  if (error is PlatformException) {
    final rawMsg = error.message ?? '';
    final msg = rawMsg.toLowerCase();
    final details = error.details?.toString().toLowerCase() ?? '';
    final code = error.code.toLowerCase();
    final combined = '$code $msg $details';

    if (code.contains('channel') ||
        msg.contains('missingplugin') ||
        details.contains('missingplugin')) {
      return 'A required component is missing. Rebuild the app or update from the store.';
    }
    if (code.contains('permission') ||
        msg.contains('permission denied') ||
        msg.contains('access denied')) {
      return 'Permission was denied. Open Settings and allow Photos or Camera, then try again.';
    }
    if (code == 'videoerror' ||
        _looksLikeTechnicalPlaybackText(combined) ||
        _looksLikeTechnicalPlaybackText(rawMsg)) {
      return _playbackRecoveryMessage();
    }
    if (msg.contains('no space') || msg.contains('storage')) {
      return 'Not enough storage. Free some space and try again.';
    }
    // Benign short native hints only (never decoder dumps or stack traces).
    if (rawMsg.isNotEmpty &&
        rawMsg.length < 90 &&
        !msg.contains('exception') &&
        !_looksLikeTechnicalPlaybackText(rawMsg)) {
      return rawMsg;
    }
  }
  final t = error.toString().toLowerCase();
  if (t.contains('missingplugin')) {
    return 'A required plugin is missing. Rebuild or reinstall the app.';
  }
  if (t.contains('socket') || t.contains('network')) {
    return 'Network issue. Check your connection and try again.';
  }
  if (_looksLikeTechnicalPlaybackText(t)) {
    return _playbackRecoveryMessage();
  }
  if (context == 'duration' ||
      t.contains('duration') ||
      t.contains('metadata') ||
      t.contains('could not read')) {
    return 'Could not read this video. Try another file or export as MP4.';
  }
  if (context == 'audio') {
    return 'Playback could not start. Try again or pick another track.';
  }
  return 'Something went wrong. Please try again.';
}
