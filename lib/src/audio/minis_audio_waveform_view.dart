import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String _kViewType = 'loopit/minis/audio/waveform';

enum MinisWaveformMode { static, live }

/// Hosts the native `loopit/minis/audio/waveform` PlatformView. On unsupported
/// platforms (web, desktop) renders a flat container so call sites compile.
class MinisWaveform extends StatefulWidget {
  const MinisWaveform({
    super.key,
    this.peaks = const <double>[],
    this.rms = const <double>[],
    this.mode = MinisWaveformMode.static,
    this.color = const Color(0xFFFFFFFF),
    this.backgroundColor = const Color(0x00000000),
    this.progressColor = const Color(0xFFFF3366),
    this.progressMs = 0,
    this.durationMs = 0,
    this.barWidthDp = 2.0,
    this.barGapDp = 1.5,
  });

  final List<double> peaks;
  final List<double> rms;
  final MinisWaveformMode mode;
  final Color color;
  final Color backgroundColor;
  final Color progressColor;
  final int progressMs;
  final int durationMs;
  final double barWidthDp;
  final double barGapDp;

  @override
  State<MinisWaveform> createState() => _MinisWaveformState();
}

class _MinisWaveformState extends State<MinisWaveform> {
  MethodChannel? _channel;

  Map<String, dynamic> _params() => {
        'peaks': widget.peaks,
        'rms': widget.rms,
        'mode': widget.mode.name,
        'color': widget.color.toARGB32(),
        'bgColor': widget.backgroundColor.toARGB32(),
        'progressColor': widget.progressColor.toARGB32(),
        'progressMs': widget.progressMs,
        'durationMs': widget.durationMs,
        'barWidthDp': widget.barWidthDp,
        'barGapDp': widget.barGapDp,
      };

  @override
  void didUpdateWidget(covariant MinisWaveform old) {
    super.didUpdateWidget(old);
    final ch = _channel;
    if (ch == null) return;
    ch.invokeMethod('update', _params()).catchError((_) {});
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('loopit/minis/audio/waveform/$id');
  }

  void appendLive(double peak) {
    final ch = _channel;
    if (ch == null) return;
    ch.invokeMethod('appendLive', peak).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Container(color: widget.backgroundColor);
    }
    if (Platform.isAndroid) {
      return AndroidView(
        viewType: _kViewType,
        creationParams: _params(),
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }
    if (Platform.isIOS) {
      return UiKitView(
        viewType: _kViewType,
        creationParams: _params(),
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }
    return Container(color: widget.backgroundColor);
  }
}
