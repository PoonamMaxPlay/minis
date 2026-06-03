import 'package:flutter/services.dart';

class NativeShare {
  NativeShare._();
  static const _ch = MethodChannel('loopit/minis/share');

  static Future<void> share({List<String> paths = const [], String? text, String? subject}) {
    return _ch.invokeMethod('share', {'paths': paths, 'text': text, 'subject': subject});
  }
}
