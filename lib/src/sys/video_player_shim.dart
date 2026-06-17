import 'package:flutter/widgets.dart';

import 'native_video_player.dart';

export 'native_video_player.dart'
    show NativeVideoPlayerController, NativeVideoPlayerView, NativePlayerValue, VideoPlayerOptions;

typedef VideoPlayerController = NativeVideoPlayerController;
typedef VideoPlayerValue = NativePlayerValue;

class VideoPlayer extends StatelessWidget {
  final NativeVideoPlayerController controller;
  const VideoPlayer(this.controller, {super.key});

  @override
  Widget build(BuildContext context) => NativeVideoPlayerView(controller: controller);
}
