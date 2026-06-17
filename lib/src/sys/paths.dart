import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';

class NativePaths {
  NativePaths._();
  static const _ch = MethodChannel('loopit/minis/paths');

  static String? _cacheDirSync;
  static String? _documentsDirSync;
  static String? _appSupportDirSync;
  static String? _externalDirSync;

  static String? get cacheDirSyncOrNull => _cacheDirSync;
  static String? get documentsDirSyncOrNull => _documentsDirSync;
  static String? get appSupportDirSyncOrNull => _appSupportDirSync;
  static String? get externalDirSyncOrNull => _externalDirSync;

  static Future<void> initSync() async {
    _cacheDirSync ??= await cacheDir();
    _documentsDirSync ??= await documentsDir();
    _appSupportDirSync ??= await appSupportDir();
    if (Platform.isAndroid) {
      _externalDirSync ??= await externalDir();
    }
  }

  static Future<String?> cacheDir() async {
    final r = await _ch.invokeMapMethod<String, Object?>('cacheDir');
    return r?['path'] as String?;
  }

  static Future<String?> appSupportDir() async {
    final r = await _ch.invokeMapMethod<String, Object?>('appSupportDir');
    return r?['path'] as String?;
  }

  static Future<String?> documentsDir() async {
    final r = await _ch.invokeMapMethod<String, Object?>('documentsDir');
    return r?['path'] as String?;
  }

  static Future<String?> externalDir() async {
    final r = await _ch.invokeMapMethod<String, Object?>('externalDir');
    return r?['path'] as String?;
  }

  static Future<String> tempFile({String ext = 'tmp'}) async {
    final r = await _ch.invokeMapMethod<String, Object?>('tempFile', {'ext': ext});
    return (r?['path'] as String?) ?? '';
  }

  static String join(List<String> parts) {
    final sep = Platform.pathSeparator;
    final out = StringBuffer();
    for (var i = 0; i < parts.length; i++) {
      var s = parts[i];
      if (s.isEmpty) continue;
      if (out.isNotEmpty) {
        final endsSep = out.toString().endsWith(sep);
        final startsSep = s.startsWith(sep);
        if (endsSep && startsSep) {
          s = s.substring(1);
        } else if (!endsSep && !startsSep) {
          out.write(sep);
        }
      }
      out.write(s);
    }
    return out.toString();
  }

  static String extension(String path) {
    final base = basename(path);
    final dot = base.lastIndexOf('.');
    if (dot <= 0 || dot == base.length - 1) return '';
    return base.substring(dot);
  }

  static String basename(String path) {
    if (path.isEmpty) return '';
    var end = path.length;
    while (end > 0 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
      end--;
    }
    if (end == 0) return '';
    var i = end - 1;
    while (i >= 0 && path[i] != '/' && path[i] != r'\') {
      i--;
    }
    return path.substring(i + 1, end);
  }

  static String basenameWithoutExtension(String path) {
    final b = basename(path);
    final dot = b.lastIndexOf('.');
    if (dot <= 0) return b;
    return b.substring(0, dot);
  }
}
