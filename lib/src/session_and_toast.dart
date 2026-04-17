import 'dart:async';

import 'package:flutter/material.dart';

/// Shown when the user enters the reel (Mini) camera section.
const String kMinisEditorToastMessage = 'Minis video tools';

/// Simple dark pill at the **top** (safe area), non-blocking. Replaces default
/// bottom [SnackBar] toasts for Minis flows.
void showMinisToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 2400),
}) {
  if (!context.mounted || message.isEmpty) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  final top = MediaQuery.paddingOf(context).top;
  late final OverlayEntry entry;

  entry = OverlayEntry(
    builder: (ctx) {
      return Positioned(
        top: top + 8,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xE61C1C1E),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: DefaultTextStyle.merge(
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.25,
                    fontWeight: FontWeight.w400,
                  ),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(entry);
  Future<void>.delayed(duration, entry.remove);
}

/// One-shot toast when entering the Minis session (camera / editor shell).
void showMinisEditorToast(BuildContext context) {
  showMinisToast(context, kMinisEditorToastMessage,
      duration: const Duration(seconds: 3));
}

/// Wraps the reel camera UI and shows [showMinisEditorToast] once after the
/// first frame.
class MinisSession extends StatefulWidget {
  const MinisSession({super.key, required this.child});

  final Widget child;

  @override
  State<MinisSession> createState() => _MinisSessionState();
}

class _MinisSessionState extends State<MinisSession> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showMinisEditorToast(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
