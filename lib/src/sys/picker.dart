import 'package:flutter/services.dart';

class PickedItem {
  final String path;
  final String mime;
  final int size;
  final int width;
  final int height;
  final int durationMs;
  final String? name;
  const PickedItem({
    required this.path,
    required this.mime,
    required this.size,
    this.width = 0,
    this.height = 0,
    this.durationMs = 0,
    this.name,
  });

  factory PickedItem.fromMap(Map<Object?, Object?> m) => PickedItem(
    path: (m['path'] as String?) ?? '',
    mime: (m['mime'] as String?) ?? '',
    size: (m['size'] as num?)?.toInt() ?? 0,
    width: (m['w'] as num?)?.toInt() ?? 0,
    height: (m['h'] as num?)?.toInt() ?? 0,
    durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
    name: m['name'] as String?,
  );
}

class NativePicker {
  NativePicker._();
  static const _ch = MethodChannel('loopit/minis/picker');

  static Future<PickedItem?> pickImage({String source = 'gallery', int? maxW, int? maxH, int quality = 90}) async {
    final r = await _ch.invokeMapMethod<Object?, Object?>('pickImage', {
      'source': source, 'maxW': maxW, 'maxH': maxH, 'quality': quality,
    });
    if (r == null) return null;
    return PickedItem.fromMap(r);
  }

  static Future<PickedItem?> pickVideo({String source = 'gallery', int? maxDurationMs}) async {
    final r = await _ch.invokeMapMethod<Object?, Object?>('pickVideo', {
      'source': source, 'maxDurationMs': maxDurationMs,
    });
    if (r == null) return null;
    return PickedItem.fromMap(r);
  }

  static Future<List<PickedItem>> pickMedia({bool multi = false, List<String> types = const ['image', 'video']}) async {
    final r = await _ch.invokeMapMethod<String, Object?>('pickMedia', {'multi': multi, 'types': types});
    final items = (r?['items'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((e) => PickedItem.fromMap(e.cast<Object?, Object?>()))
        .toList();
  }

  static Future<List<PickedItem>> pickFile({bool multi = false, List<String> mimeTypes = const [], List<String> extensions = const []}) async {
    final r = await _ch.invokeMapMethod<String, Object?>('pickFile', {
      'multi': multi, 'mimeTypes': mimeTypes, 'extensions': extensions,
    });
    final items = (r?['items'] as List?) ?? const [];
    return items
        .whereType<Map>()
        .map((e) => PickedItem.fromMap(e.cast<Object?, Object?>()))
        .toList();
  }

  static Future<String?> saveToGallery({required String path, String? album}) async {
    final r = await _ch.invokeMapMethod<String, Object?>('saveToGallery', {'path': path, 'album': album});
    return r?['uri'] as String?;
  }
}
