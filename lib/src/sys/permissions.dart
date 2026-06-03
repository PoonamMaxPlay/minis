import 'package:flutter/services.dart';

enum PermissionStatus { granted, denied, permDenied, restricted }

PermissionStatus _parse(String? s) {
  switch (s) {
    case 'granted': return PermissionStatus.granted;
    case 'permDenied': return PermissionStatus.permDenied;
    case 'restricted': return PermissionStatus.restricted;
    default: return PermissionStatus.denied;
  }
}

class NativePermissions {
  NativePermissions._();
  static const _ch = MethodChannel('loopit/minis/permissions');
  static const _events = EventChannel('loopit/minis/permissions/events');

  static Future<PermissionStatus> check(String key) async {
    final r = await _ch.invokeMapMethod<String, Object?>('check', {'permission': key});
    return _parse(r?['status'] as String?);
  }

  static Future<PermissionStatus> request(String key) async {
    final r = await _ch.invokeMapMethod<String, Object?>('request', {'permission': key});
    return _parse(r?['status'] as String?);
  }

  static Future<Map<String, PermissionStatus>> requestMulti(List<String> keys) async {
    final r = await _ch.invokeMapMethod<String, Object?>('requestMulti', {'permissions': keys});
    final map = (r?['map'] as Map?)?.cast<String, Object?>() ?? {};
    return map.map((k, v) => MapEntry(k, _parse(v as String?)));
  }

  static Future<void> openSettings() => _ch.invokeMethod('openSettings');

  static Stream<Map<String, Object?>> events() =>
      _events.receiveBroadcastStream().map((e) => (e as Map).cast<String, Object?>());
}
