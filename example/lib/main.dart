import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

import 'minis_example_save.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MinisCaptureHost.register(
    ({bool videoOnly = false}) => MinisIndependentCaptureScreen(
      videoOnly: videoOnly,
      onClipConfirmed: (path) {
        unawaited(MinisExampleSave.saveAndNotify(path));
      },
    ),
  );
  runApp(const MinisExampleApp());
}

/// Runnable without LoopIt: **independent** capture via `package:camera` (no Retrytech).
class MinisExampleApp extends StatelessWidget {
  const MinisExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Minis',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: MinisSession(
        child: MinisIndependentCaptureScreen(
          onClipConfirmed: (path) {
            unawaited(MinisExampleSave.saveAndNotify(path));
          },
        ),
      ),
    );
  }
}
