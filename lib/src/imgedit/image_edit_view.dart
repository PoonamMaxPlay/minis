import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'image_edit_channel.dart';

/// Hosts the native render surface — Android `SurfaceView` (GLES 3) or iOS
/// `MTKView` (Metal). Backed by `loopit/minis/imgedit/canvas` PlatformView
/// factory registered in `LoopitMinisPlugin` on both platforms.
class MinisImageEditPlatformView extends StatelessWidget {
  const MinisImageEditPlatformView({
    super.key,
    required this.sourcePath,
    this.onPlatformViewCreated,
    this.gestureRecognizers,
  });

  final String sourcePath;
  final ValueChanged<int>? onPlatformViewCreated;
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;

  @override
  Widget build(BuildContext context) {
    const String viewType = MinisImageEditChannel.platformViewType;
    final creationParams = <String, dynamic>{
      'sourcePath': sourcePath,
    };
    final recognizers = gestureRecognizers ??
        const <Factory<OneSequenceGestureRecognizer>>{};

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: onPlatformViewCreated,
          gestureRecognizers: recognizers,
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: onPlatformViewCreated,
          gestureRecognizers: recognizers,
        );
      default:
        return _UnsupportedPlatformView(sourcePath: sourcePath);
    }
  }
}

class _UnsupportedPlatformView extends StatelessWidget {
  const _UnsupportedPlatformView({required this.sourcePath});
  final String sourcePath;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Text(
        'Minis image editor not available on this platform.\n$sourcePath',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70),
      ),
    );
  }
}
