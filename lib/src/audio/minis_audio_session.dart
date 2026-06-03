import 'dart:async';

import 'minis_audio_channel.dart';

/// API-compatible subset of `audio_session` backed by the native Minis audio
/// engine. Only the symbols used by the Minis package are mirrored.
class AVAudioSessionCategory {
  const AVAudioSessionCategory._(this.raw);
  final String raw;

  static const ambient = AVAudioSessionCategory._('ambient');
  static const soloAmbient = AVAudioSessionCategory._('soloAmbient');
  static const playback = AVAudioSessionCategory._('playback');
  static const record = AVAudioSessionCategory._('record');
  static const playAndRecord = AVAudioSessionCategory._('playAndRecord');
  static const multiRoute = AVAudioSessionCategory._('multiRoute');
}

class AVAudioSessionCategoryOptions {
  const AVAudioSessionCategoryOptions(this.value);
  final int value;

  static const none = AVAudioSessionCategoryOptions(0);
  static const mixWithOthers = AVAudioSessionCategoryOptions(0x1);
  static const duckOthers = AVAudioSessionCategoryOptions(0x2);
  static const allowBluetooth = AVAudioSessionCategoryOptions(0x4);
  static const defaultToSpeaker = AVAudioSessionCategoryOptions(0x8);
  static const interruptSpokenAudioAndMixWithOthers =
      AVAudioSessionCategoryOptions(0x11);
  static const allowBluetoothA2DP = AVAudioSessionCategoryOptions(0x20);
  static const allowAirPlay = AVAudioSessionCategoryOptions(0x40);

  AVAudioSessionCategoryOptions operator |(AVAudioSessionCategoryOptions o) =>
      AVAudioSessionCategoryOptions(value | o.value);
}

class AVAudioSessionMode {
  const AVAudioSessionMode._(this.raw);
  final String raw;

  static const defaultMode = AVAudioSessionMode._('default');
  static const gameChat = AVAudioSessionMode._('gameChat');
  static const measurement = AVAudioSessionMode._('measurement');
  static const moviePlayback = AVAudioSessionMode._('moviePlayback');
  static const spokenAudio = AVAudioSessionMode._('spokenAudio');
  static const videoChat = AVAudioSessionMode._('videoChat');
  static const videoRecording = AVAudioSessionMode._('videoRecording');
  static const voiceChat = AVAudioSessionMode._('voiceChat');
}

class AndroidAudioContentType {
  const AndroidAudioContentType._(this.raw);
  final String raw;
  static const unknown = AndroidAudioContentType._('unknown');
  static const speech = AndroidAudioContentType._('speech');
  static const music = AndroidAudioContentType._('music');
  static const movie = AndroidAudioContentType._('movie');
  static const sonification = AndroidAudioContentType._('sonification');
}

class AndroidAudioUsage {
  const AndroidAudioUsage._(this.raw);
  final String raw;
  static const unknown = AndroidAudioUsage._('unknown');
  static const media = AndroidAudioUsage._('media');
  static const voiceCommunication = AndroidAudioUsage._('voiceCommunication');
  static const alarm = AndroidAudioUsage._('alarm');
  static const notification = AndroidAudioUsage._('notification');
  static const game = AndroidAudioUsage._('game');
}

class AndroidAudioFocusGainType {
  const AndroidAudioFocusGainType._(this.raw);
  final String raw;
  static const gain = AndroidAudioFocusGainType._('gain');
  static const gainTransient = AndroidAudioFocusGainType._('gainTransient');
  static const gainTransientMayDuck =
      AndroidAudioFocusGainType._('gainTransientMayDuck');
  static const gainTransientExclusive =
      AndroidAudioFocusGainType._('gainTransientExclusive');
}

class AndroidAudioAttributes {
  const AndroidAudioAttributes({
    this.contentType = AndroidAudioContentType.unknown,
    this.usage = AndroidAudioUsage.unknown,
  });

  final AndroidAudioContentType contentType;
  final AndroidAudioUsage usage;

  Map<String, dynamic> toMap() => {
        'contentType': contentType.raw,
        'usage': usage.raw,
      };
}

class AudioSessionConfiguration {
  const AudioSessionConfiguration({
    this.avAudioSessionCategory,
    this.avAudioSessionCategoryOptions,
    this.avAudioSessionMode,
    this.androidAudioAttributes,
    this.androidAudioFocusGainType,
  });

  final AVAudioSessionCategory? avAudioSessionCategory;
  final AVAudioSessionCategoryOptions? avAudioSessionCategoryOptions;
  final AVAudioSessionMode? avAudioSessionMode;
  final AndroidAudioAttributes? androidAudioAttributes;
  final AndroidAudioFocusGainType? androidAudioFocusGainType;

  Map<String, dynamic> toMap() => {
        if (avAudioSessionCategory != null)
          'category': avAudioSessionCategory!.raw,
        if (avAudioSessionCategoryOptions != null)
          'categoryOptions': avAudioSessionCategoryOptions!.value,
        if (avAudioSessionMode != null) 'mode': avAudioSessionMode!.raw,
        if (androidAudioAttributes != null)
          'androidAttrs': androidAudioAttributes!.toMap(),
        if (androidAudioFocusGainType != null)
          'androidFocusGain': androidAudioFocusGainType!.raw,
      };
}

class AudioSession {
  AudioSession._();
  static final AudioSession _i = AudioSession._();

  /// `audio_session` mirror: `await AudioSession.instance`.
  static Future<AudioSession> get instance async => _i;

  Future<bool> configure(AudioSessionConfiguration cfg) async {
    final res = await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>(
      'configureSession',
      cfg.toMap(),
    );
    return (res?['accepted'] as bool?) ?? true;
  }

  Future<bool> setActive(bool active) async {
    final res = await minisAudioChannel.invokeMethod<Map<dynamic, dynamic>>(
      'setSessionActive',
      {'active': active},
    );
    return (res?['active'] as bool?) ?? active;
  }
}
