import 'dart:async';

import 'package:flutter/services.dart';

/// Where telemetry events get delivered.
///
/// * [log] — emit via `print` / platform log only (zero overhead for host).
/// * [stream] — emit on [MinisTelemetry.events] for the host to fan out.
enum TelemetrySink { log, stream }

/// One telemetry record.
///
/// Fields carry only structural data — operation kind, durations, codec
/// strings, thermal-state enum values, result codes, error codes. No file
/// paths, URIs, raw bytes, host identifiers, or user-content strings.
class MinisTelemetryEvent {
  final String name;
  final int tsMs;
  final Map<String, Object?> fields;

  const MinisTelemetryEvent({
    required this.name,
    required this.tsMs,
    required this.fields,
  });

  factory MinisTelemetryEvent.fromMap(Map<dynamic, dynamic> raw) {
    final fields = <String, Object?>{};
    final src = raw['fields'];
    if (src is Map) {
      src.forEach((k, v) {
        fields[k.toString()] = v;
      });
    }
    return MinisTelemetryEvent(
      name: (raw['name'] ?? '').toString(),
      tsMs: (raw['ts'] as num?)?.toInt() ?? 0,
      fields: fields,
    );
  }

  @override
  String toString() => '[$tsMs] $name $fields';
}

/// Opt-in observability for the Minis plugin.
///
/// Off by default. Hosts opt in with:
/// ```dart
/// await MinisTelemetry.instance.enable(sink: TelemetrySink.stream);
/// MinisTelemetry.instance.events.listen((e) => print(e));
/// ```
class MinisTelemetry {
  MinisTelemetry._();
  static final MinisTelemetry instance = MinisTelemetry._();

  static const MethodChannel _method = MethodChannel('loopit/minis/telemetry');
  static const EventChannel _events = EventChannel('loopit/minis/telemetry/events');

  Stream<MinisTelemetryEvent>? _eventStream;
  bool _enabled = false;
  TelemetrySink _sink = TelemetrySink.log;

  bool get isEnabled => _enabled;
  TelemetrySink get sink => _sink;

  /// Turn telemetry on. Returns true if the native side accepted; false on
  /// platforms where the channel isn't registered (host can keep going).
  Future<bool> enable({TelemetrySink sink = TelemetrySink.log}) async {
    try {
      await _method.invokeMethod<void>('enable', {'sink': sink.name});
      _enabled = true;
      _sink = sink;
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> disable() async {
    try {
      await _method.invokeMethod<void>('disable');
    } on MissingPluginException {
      // ignore — host can call before plugin attaches
    }
    _enabled = false;
  }

  /// Dart-originated event. Native engines emit via their own pipeline; this
  /// lets the host log app-level events through the same surface.
  Future<void> emit(String name, [Map<String, Object?> fields = const {}]) async {
    if (!_enabled) return;
    try {
      await _method.invokeMethod<void>('emit', {
        'name': name,
        'fields': _scrub(fields),
      });
    } on MissingPluginException {
      // ignore
    } on PlatformException {
      // swallow — telemetry must never crash the host
    }
  }

  /// Broadcast stream of events from the native pipeline plus any Dart
  /// `emit` calls re-broadcast from the native side. Only carries data when
  /// [enable] was called with [TelemetrySink.stream].
  Stream<MinisTelemetryEvent> get events {
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map((raw) => MinisTelemetryEvent.fromMap(raw as Map))
        .handleError((_) {}, test: (_) => true);
  }

  /// Drop anything that looks like a path, URI, or freeform user string.
  Map<String, Object?> _scrub(Map<String, Object?> input) {
    const allow = <String>{
      'op', 'kind', 'durationMs', 'pct', 'fps', 'codec', 'profile',
      'width', 'height', 'sampleRate', 'channels', 'bitrateKbps',
      'thermal', 'battery', 'state', 'result', 'errorCode',
      'taskId', 'segments', 'count', 'reason',
    };
    final out = <String, Object?>{};
    input.forEach((k, v) {
      if (!allow.contains(k)) return;
      if (v is String && v.length > 64) return;
      out[k] = v;
    });
    return out;
  }
}
