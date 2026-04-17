import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/src/native_video_trim_user_message.dart';

void main() {
  test('VideoError Exo/MediaCodec message maps to trim decoder copy', () {
    const longExo =
        'Video player had error androidx.media3.exoplayer.ExoPlaybackException: '
        'MediaCodecVideoRenderer error, index=0, format=Format(2, null, video/mp4';
    final m = messageForVideoTrimFailure(
      PlatformException(code: 'VideoError', message: longExo),
    );
    expect(m.toLowerCase(), contains('could not be trimmed'));
    expect(m.toLowerCase(), isNot(contains('exoplayback')));
    expect(m.toLowerCase(), isNot(contains('mediacodec')));
  });

  test('TRIM_ERROR with decoder dump uses trim recovery', () {
    const msg =
        'PlatformException(VideoError, Video player had error androidx.media3';
    final m = messageForVideoTrimFailure(
      PlatformException(code: 'TRIM_ERROR', message: msg),
    );
    expect(m.toLowerCase(), contains('could not be trimmed'));
  });
}
