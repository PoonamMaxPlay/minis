import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

import 'create_feed_screen.dart';
import 'example_capture_mode.dart';
import 'example_mode_chips.dart';
import 'editor/editor_screen.dart';
import 'story_edit_screen.dart';

/// Camera-first home for the example app. Each mode opens Minis capture and
/// then routes the confirmed clip to a preview/composer screen:
///   - reel  → MinisIndependentCaptureScreen(videoOnly: true)  →
///             ReelEditScreen → Next → CreateFeedScreen(reel) preview.
///   - story → MinisIndependentCaptureScreen(videoOnly: false) →
///             StoryEditScreen → Post saves to app storage.
///   - feed  → MinisIndependentCaptureScreen(videoOnly: false) →
///             CreateFeedScreen(feed, initialMediaPath) preview.
///
/// Selection persists via [ExampleCaptureModeStore] (SharedPreferences,
/// default = reel).
class ExampleCaptureHome extends StatefulWidget {
  const ExampleCaptureHome({super.key});

  @override
  State<ExampleCaptureHome> createState() => _ExampleCaptureHomeState();
}

class _ExampleCaptureHomeState extends State<ExampleCaptureHome> {
  ExampleCaptureMode? _mode;
  int _cameraRevision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // Capture screen drives the camera — keep the display on while it's up
    // so a quiet recording doesn't trip the system auto-lock. The native
    // wakelock release lands on `dispose`.
    unawaited(NativeWakelock.enable());
  }

  Future<void> _load() async {
    final m = await ExampleCaptureModeStore.load();
    if (!mounted) return;
    setState(() => _mode = m);
  }

  @override
  void dispose() {
    unawaited(NativeWakelock.disable());
    super.dispose();
  }

  Future<void> _onSelect(ExampleCaptureMode next) async {
    if (next == _mode) return;
    await ExampleCaptureModeStore.save(next);
    if (!mounted) return;
    setState(() {
      _mode = next;
      _cameraRevision++;
    });
  }

  void _onClipConfirmed(String path) {
    final mode = _mode;
    if (mode == ExampleCaptureMode.reel) {
      Get.to<void>(() => VideoEditorScreen(videoPath: path));
    } else if (mode == ExampleCaptureMode.story) {
      Get.to<void>(() => StoryEditScreen(mediaPath: path));
    } else if (mode == ExampleCaptureMode.feed) {
      Get.to<void>(
        () => CreateFeedScreen(
          createType: CreateFeedType.feed,
          initialMediaPath: path,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = _mode;
    if (mode == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody(mode)),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: Container(
                padding: const EdgeInsets.only(top: 56, bottom: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.55),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                  ),
                ),
                child: ExampleModeChips(
                  currentMode: mode,
                  onSelect: _onSelect,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ExampleCaptureMode mode) {
    return MinisIndependentCaptureScreen(
      key: ValueKey<String>('capture_${mode.name}_$_cameraRevision'),
      videoOnly: mode.videoOnly,
      onClipConfirmed: _onClipConfirmed,
    );
  }
}
