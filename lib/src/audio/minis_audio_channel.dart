import 'package:flutter/services.dart';

const String kMinisAudioMethodChannel = 'loopit/minis/audio';
const String kMinisAudioPlayerEventsChannel = 'loopit/minis/audio/playerEvents';
const String kMinisAudioLevelsChannel = 'loopit/minis/audio/levels';

const MethodChannel minisAudioChannel = MethodChannel(kMinisAudioMethodChannel);
const EventChannel minisAudioPlayerEvents =
    EventChannel(kMinisAudioPlayerEventsChannel);
const EventChannel minisAudioLevels = EventChannel(kMinisAudioLevelsChannel);
