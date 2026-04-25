import 'package:flutter/material.dart';

import 'package:loopit_minis/src/hub_page.dart';

/// Default capture surface for the **standalone example** app.
///
/// LoopIt replaces this by calling [MinisCaptureHost.register] with
/// `LoopItCameraScreen(mode: reels)` (or equivalent).
class MinisCapturePlaceholder extends StatelessWidget {
  const MinisCapturePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: const Icon(
                  Icons.arrow_back_ios_new,
                  color: Colors.white,
                  size: 20,
                ),
                onPressed: () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: 'Video hub',
                icon: const Icon(
                  Icons.video_library_outlined,
                  color: Colors.white,
                  size: 26,
                ),
                onPressed: () => MinisVideoHubPage.open(context),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Minis capture',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'This app is the lightweight Minis package sample.\n\n'
                      'For the full Minis camera (preview, record, tools), run '
                      'LoopIt with the standalone entry:\n'
                      'flutter run -t lib/minis_standalone_main.dart\n\n'
                      'Inside LoopIt, the sheet opens that screen via '
                      'MinisCaptureHost.register(...).',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        height: 1.45,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
