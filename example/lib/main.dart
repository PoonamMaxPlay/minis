import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:loopit_minis/loopit_minis.dart';

import 'example_capture_home.dart';
import 'minis_example_save.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Capture screen — host the native engine through MinisCaptureHost so the
  // hub routes "reel / story / feed" presses straight into the native camera
  // pipeline (improvement1.md). The host plugs the example's "saveAndNotify"
  // sink in for the on-clip confirmation step.
  MinisCaptureHost.register(
    ({bool videoOnly = false}) => MinisIndependentCaptureScreen(
      videoOnly: videoOnly,
      onClipConfirmed: (path) {
        unawaited(MinisExampleSave.saveAndNotify(path));
      },
    ),
  );

  // Telemetry — opt in to the stream sink so debug builds print events as
  // the engines emit them (capture start/stop, export progress, thermal,
  // crash-recovered). Field allow-list scrubs paths/URIs server-side.
  if (kDebugMode) {
    unawaited(_attachTelemetry());
  }

  runApp(const MinisExampleApp());
}

Future<void> _attachTelemetry() async {
  final ok = await MinisTelemetry.instance.enable(sink: TelemetrySink.stream);
  if (!ok) return;
  MinisTelemetry.instance.events.listen(
    (e) => debugPrint('telemetry: ${e.name} ${e.fields}'),
    onError: (_) {},
  );
  await MinisTelemetry.instance.emit('example.boot', {
    'op': 'startup',
    'result': 'ok',
  });
}

/// Runnable without LoopIt: **independent** capture via the native engine
/// (improvement1.md — `loopit/minis/camera`). No Retrytech.
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
      home: const MinisSession(child: ExampleCaptureHome()),
    );
  }
}
