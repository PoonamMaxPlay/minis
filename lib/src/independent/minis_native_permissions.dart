import 'package:flutter/services.dart';

/// Thin wrapper over the native `loopit/minis/permissions` channel.
///
/// Mirrors the runtime permissions exposed by the Minis native camera plugin
/// (Android `MinisPermissions`, iOS `MinisCameraPermissions`). Returns `false`
/// on any platform exception so callers can fall back gracefully.
class MinisNativePermissions {
  static const MethodChannel _ch = MethodChannel('loopit/minis/permissions');

  static Future<bool> requestCamera() async {
    try {
      final v = await _ch.invokeMethod<bool>('requestCamera');
      return v ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> requestMicrophone() async {
    try {
      final v = await _ch.invokeMethod<bool>('requestMicrophone');
      return v ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<Map<String, bool>> status() async {
    try {
      final m = await _ch.invokeMapMethod<dynamic, dynamic>('status');
      return {
        'camera': m?['camera'] == true,
        'microphone': m?['microphone'] == true,
      };
    } on PlatformException {
      return const {'camera': false, 'microphone': false};
    }
  }
}
