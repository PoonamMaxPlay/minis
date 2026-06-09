import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Renders a deterministic placeholder waveform for the given audio [path].
///
/// Real PCM extraction would require a native plugin; instead we derive a
/// stable pseudo-amplitude list from the path's [hashCode] so the same file
/// always shows the same visual without any I/O.
class AudioWaveform extends StatelessWidget {
  const AudioWaveform({
    super.key,
    required this.path,
    required this.width,
    required this.height,
    required this.color,
    this.barCount = 60,
    this.muted = false,
  });

  final String path;
  final double width;
  final double height;
  final Color color;
  final int barCount;
  final bool muted;

  static List<double> _amplitudes(String path, int barCount) {
    final seed = path.hashCode;
    final out = <double>[];
    for (var i = 0; i < barCount; i++) {
      final x = (seed ^ (i * 2654435761)) & 0x7fffffff;
      final a = math.sin(x * 0.0001 + i * 0.37).abs();
      final b = math.sin((seed % 997) * 0.013 + i * 0.91).abs();
      final frac = ((a + b) * 0.5);
      final v = frac - frac.floor();
      out.add(0.15 + v * 0.85);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final amps = _amplitudes(path, barCount);
    final drawColor = muted ? color.withValues(alpha: 0.3) : color.withValues(alpha: 1.0);
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        size: Size(width, height),
        painter: _WaveformPainter(
          path: path,
          width: width,
          color: drawColor,
          amplitudes: amps,
          barCount: barCount,
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.path,
    required this.width,
    required this.color,
    required this.amplitudes,
    required this.barCount,
  });

  final String path;
  final double width;
  final Color color;
  final List<double> amplitudes;
  final int barCount;

  @override
  void paint(Canvas canvas, Size size) {
    final slot = size.width / barCount;
    final barW = slot * 0.6;
    final centerY = size.height / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = barW
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < barCount; i++) {
      final amp = amplitudes[i];
      final half = (size.height * 0.5) * amp;
      final x = slot * i + slot / 2;
      canvas.drawLine(
        Offset(x, centerY - half),
        Offset(x, centerY + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) {
    return old.path != path ||
        old.width != width ||
        old.color != color ||
        old.barCount != barCount;
  }
}
