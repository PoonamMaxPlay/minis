import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopit_minis/src/minis_user_message.dart';

void main() {
  test('MissingPluginException is friendly', () {
    final m = minisUserFriendlyException(
      MissingPluginException('pickMedia'),
    );
    expect(m.toLowerCase(), contains('not available'));
  });

  test('PlatformException channel maps to rebuild hint', () {
    final m = minisUserFriendlyException(
      PlatformException(code: 'channel-error', message: 'missing'),
    );
    expect(m.toLowerCase(), isNot(contains('platformexception')));
  });

  test('VideoError / Exo long message is not shown raw', () {
    const longExo =
        'Video player had error androidx.media3.exoplayer.ExoPlaybackException: '
        'MediaCodecVideoRenderer error, index=0, format=Format(1, null, video/mp4';
    final m = minisUserFriendlyException(
      PlatformException(code: 'VideoError', message: longExo),
    );
    expect(m.toLowerCase(), isNot(contains('exoplayback')));
    expect(m.toLowerCase(), isNot(contains('mediacodec')));
    expect(m.toLowerCase(), isNot(contains('format(')));
    expect(m, contains('could not be played'));
  });

  test('Decoder dump via toString still maps to recovery', () {
    final m = minisUserFriendlyException(
      'androidx.media3.exoplayer.ExoPlaybackException: MediaCodecVideoRenderer',
    );
    expect(m, contains('could not be played'));
  });

  test('audio context gives playback hint for unknown errors', () {
    final m = minisUserFriendlyException(
      Exception('unknown'),
      context: 'audio',
    );
    expect(m.toLowerCase(), contains('playback'));
  });
}
