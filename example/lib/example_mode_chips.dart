import 'package:flutter/material.dart';

import 'example_capture_mode.dart';

/// Mirrors LoopIt's `LoopItCameraModeChips` (story/feed/reel) at the bottom of
/// the camera shell. Tapping a chip persists the choice and rebuilds the host.
class ExampleModeChips extends StatelessWidget {
  const ExampleModeChips({
    super.key,
    required this.currentMode,
    required this.onSelect,
    this.enabled = true,
  });

  final ExampleCaptureMode currentMode;
  final ValueChanged<ExampleCaptureMode> onSelect;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < ExampleCaptureMode.values.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _ModeChip(
                mode: ExampleCaptureMode.values[i],
                selected: ExampleCaptureMode.values[i] == currentMode,
                enabled: enabled,
                onTap: ExampleCaptureMode.values[i] == currentMode
                    ? null
                    : () => onSelect(ExampleCaptureMode.values[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ExampleCaptureMode mode;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(20),
        splashColor: Colors.white24,
        highlightColor: Colors.white10,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            constraints: const BoxConstraints(minHeight: 36, minWidth: 56),
            decoration: BoxDecoration(
              color: selected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Center(
              child: Text(
                mode.label,
                style: TextStyle(
                  color: selected ? Colors.black : Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
