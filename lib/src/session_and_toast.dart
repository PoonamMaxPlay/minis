import 'package:flutter/material.dart';

/// Shown when the user enters the reel (Mini) camera section.
const String kMinisEditorToastMessage = 'Minis video tools';

/// One-shot snackbar for the Minis / pro video editor session.
void showMinisEditorToast(BuildContext context) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    const SnackBar(
      content: Text(kMinisEditorToastMessage),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 3),
      margin: EdgeInsets.fromLTRB(16, 0, 16, 88),
    ),
  );
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
