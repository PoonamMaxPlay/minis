import 'package:flutter/services.dart';

class NativeWakelock {
  NativeWakelock._();
  static const _ch = MethodChannel('loopit/minis/wakelock');

  static Future<void> enable() => _ch.invokeMethod('enable');
  static Future<void> disable() => _ch.invokeMethod('disable');
}
