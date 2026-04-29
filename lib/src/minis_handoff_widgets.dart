import 'package:flutter/material.dart';

/// A standard progress indicator used during Minis video processing/handoff.
class MinisProgressIndicator extends StatelessWidget {
  const MinisProgressIndicator({
    super.key,
    this.progress,
    this.message = 'Processing video…',
  });

  /// Optional progress value (0.0 to 1.0). If null, shows indeterminate state.
  final double? progress;

  /// The message to display below the indicator.
  final String message;

  @override
  Widget build(BuildContext context) {
    final p = progress ?? 0.0;
    final percent = (p * 100).toInt().clamp(0, 100);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 84,
          height: 84,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: progress != null && progress! > 0 ? progress : null,
                strokeWidth: 8,
                color: Colors.white,
                backgroundColor: Colors.white12,
              ),
              if (progress != null)
                Text(
                  "$percent%",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}
