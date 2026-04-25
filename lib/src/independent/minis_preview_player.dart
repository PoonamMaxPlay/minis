import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

class MinisPreviewPlayerController extends ChangeNotifier {
  final List<String> paths;
  MethodChannel? _channel;
  
  bool isInitialized = false;
  Duration duration = Duration.zero;
  Duration position = Duration.zero;
  bool isPlaying = true;
  Size? videoSize;
  
  Timer? _positionTimer;
  bool _disposed = false;

  MinisPreviewPlayerController(this.paths);

  void _onPlatformViewCreated(int id) async {
    _channel = MethodChannel('minis_preview_player_$id');
    _channel?.setMethodCallHandler(_handleMethodCall);
    
    // Initial fetch of metadata
    await Future.delayed(const Duration(milliseconds: 300));
    if (_disposed) return;
    
    final durMs = await _channel?.invokeMethod<int>('getDuration') ?? 0;
    duration = Duration(milliseconds: durMs);
    
    final sizeList = await _channel?.invokeMethod<List<dynamic>>('getVideoSize');
    if (sizeList != null && sizeList.length == 2) {
      videoSize = Size(
        (sizeList[0] as num).toDouble(),
        (sizeList[1] as num).toDouble(),
      );
    }
    
    if (_disposed) return;
    isInitialized = true;
    notifyListeners();
    
    _positionTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      if (!isPlaying || _disposed) return;
      try {
        final posMs = await _channel?.invokeMethod<int>('getPosition') ?? 0;
        final durMs = await _channel?.invokeMethod<int>('getDuration') ?? 0;
        
        position = Duration(milliseconds: posMs);
        if (durMs > 0 && durMs != duration.inMilliseconds) {
          duration = Duration(milliseconds: durMs);
        }
        
        if (!_disposed) notifyListeners();
      } catch (e) {
        // Platform view was destroyed but timer fired
        timer.cancel();
      }
    });
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onEnded') {
      // Handled by native loop, but can be useful
    } else if (call.method == 'onVideoSizeChanged') {
      final sizeList = call.arguments as List<dynamic>?;
      if (sizeList != null && sizeList.length == 2) {
        final w = (sizeList[0] as num).toDouble();
        final h = (sizeList[1] as num).toDouble();
        if (w > 0 && h > 0) {
          videoSize = Size(w, h);
          if (!_disposed) notifyListeners();
        }
      }
    }
  }

  Future<void> play() async {
    isPlaying = true;
    await _channel?.invokeMethod('play');
    notifyListeners();
  }

  Future<void> pause() async {
    isPlaying = false;
    await _channel?.invokeMethod('pause');
    notifyListeners();
  }

  Future<void> seekTo(Duration time) async {
    position = time;
    notifyListeners();
    await _channel?.invokeMethod('seekTo', time.inMilliseconds);
  }

  @override
  void dispose() {
    _disposed = true;
    _positionTimer?.cancel();
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }
}

class MinisPreviewPlayerWidget extends StatelessWidget {
  final MinisPreviewPlayerController controller;

  const MinisPreviewPlayerWidget({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    const String viewType = 'minis_preview_player';
    final Map<String, dynamic> creationParams = <String, dynamic>{
      'paths': controller.paths,
    };

    Widget playerView;
    if (defaultTargetPlatform == TargetPlatform.android) {
      playerView = PlatformViewLink(
        viewType: viewType,
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          );
        },
        onCreatePlatformView: (params) {
          final AndroidViewController vc = PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: viewType,
            layoutDirection: TextDirection.ltr,
            creationParams: creationParams,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () {
              params.onFocusChanged(true);
            },
          );
          vc
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..addOnPlatformViewCreatedListener(controller._onPlatformViewCreated)
            ..create();
          return vc;
        },
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      playerView = UiKitView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: controller._onPlatformViewCreated,
      );
    } else {
      playerView = const Center(child: Text('Unsupported platform'));
    }

    if (controller.isInitialized && controller.videoSize != null) {
      final size = controller.videoSize!;
      if (size.width > 0 && size.height > 0) {
        return Center(
          child: AspectRatio(
            aspectRatio: size.width / size.height,
            child: playerView,
          ),
        );
      }
    }

    return playerView;
  }
}
