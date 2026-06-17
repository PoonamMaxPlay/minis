/// Embed widget that hosts the native preview surface produced by
/// [MinisVidEdit]. Renders an `AndroidView` / `UiKitView` when the native
/// engine is available, and a fallback placeholder otherwise.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:loopit_minis/src/videdit/videdit_engine.dart';

/// Hosts the native preview surface (Android SurfaceView, iOS UIView).
/// When the native engine is not built into the binary the widget paints a
/// dark placeholder.
class VidEditPreviewView extends StatelessWidget {
  const VidEditPreviewView({
    super.key,
    this.onPlatformViewCreated,
    this.creationParams = const <String, Object?>{},
    this.placeholderText = 'Native editor preview unavailable',
  });

  final ValueChanged<int>? onPlatformViewCreated;
  final Map<String, Object?> creationParams;
  final String placeholderText;

  bool get _eligible {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  Widget build(BuildContext context) {
    if (!_eligible || !MinisVidEdit.instance.isAvailableSync) {
      return _placeholder();
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: kVidEditPlatformViewType,
          onPlatformViewCreated: onPlatformViewCreated,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: kVidEditPlatformViewType,
          onPlatformViewCreated: onPlatformViewCreated,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
      default:
        return _placeholder();
    }
  }

  Widget _placeholder() {
    return ColoredBox(
      color: const Color(0xFF101012),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            placeholderText,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, height: 1.4),
          ),
        ),
      ),
    );
  }
}
