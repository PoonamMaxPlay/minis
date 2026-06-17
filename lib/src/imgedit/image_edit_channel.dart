import 'dart:async';

import 'package:flutter/services.dart';

import 'image_edit_layer_types.dart';

/// Wraps MethodChannel `loopit/minis/imgedit` + EventChannel
/// `loopit/minis/imgedit/state`. Mirrors the surface defined in
/// improvement2.md and implemented natively under
/// `android/.../imgedit/` and `ios/Classes/ImgEdit/`.
class MinisImageEditChannel {
  MinisImageEditChannel._();

  static final MinisImageEditChannel instance = MinisImageEditChannel._();

  static const MethodChannel _method =
      MethodChannel('loopit/minis/imgedit');
  static const EventChannel _state =
      EventChannel('loopit/minis/imgedit/state');

  /// PlatformView registration id used by Android `SurfaceView` factory
  /// and iOS `MTKView` factory.
  static const String platformViewType = 'loopit/minis/imgedit/canvas';

  Stream<MinisImageEditEvent>? _stateStream;

  Stream<MinisImageEditEvent> get events {
    return _stateStream ??= _state.receiveBroadcastStream().map((raw) {
      final map = (raw as Map?)?.cast<String, dynamic>() ?? const {};
      return MinisImageEditEvent.fromJson(map);
    });
  }

  Future<MinisImageEditSession> init({required String sourcePath}) async {
    final res = await _method.invokeMapMethod<String, dynamic>('init', {
      'sourcePath': sourcePath,
    });
    if (res == null) {
      throw const MinisImageEditException('init returned null');
    }
    return MinisImageEditSession.fromJson(res);
  }

  Future<void> dispose({required int viewId}) async {
    await _method.invokeMethod<void>('dispose', {'viewId': viewId});
  }

  Future<int> pushLayer({
    required int viewId,
    required MinisImageLayerType type,
    required Map<String, dynamic> params,
  }) async {
    final res = await _method.invokeMapMethod<String, dynamic>('pushLayer', {
      'viewId': viewId,
      'type': type.wireName,
      'params': params,
    });
    return (res?['layerId'] as num?)?.toInt() ?? -1;
  }

  Future<void> updateLayer({
    required int viewId,
    required int layerId,
    required Map<String, dynamic> params,
  }) {
    return _method.invokeMethod<void>('updateLayer', {
      'viewId': viewId,
      'layerId': layerId,
      'params': params,
    });
  }

  Future<void> removeLayer({required int viewId, required int layerId}) {
    return _method.invokeMethod<void>('removeLayer', {
      'viewId': viewId,
      'layerId': layerId,
    });
  }

  Future<void> reorderLayer({
    required int viewId,
    required int layerId,
    required int index,
  }) {
    return _method.invokeMethod<void>('reorderLayer', {
      'viewId': viewId,
      'layerId': layerId,
      'index': index,
    });
  }

  Future<void> applyAdjust({
    required int viewId,
    required String key,
    required double value,
  }) {
    return _method.invokeMethod<void>('applyAdjust', {
      'viewId': viewId,
      'key': key,
      'value': value,
    });
  }

  Future<void> applyFilter({
    required int viewId,
    required String lutPath,
    required double intensity,
  }) {
    return _method.invokeMethod<void>('applyFilter', {
      'viewId': viewId,
      'lutPath': lutPath,
      'intensity': intensity,
    });
  }

  Future<void> applyCrop({
    required int viewId,
    required Rect rect,
    required double rotationDeg,
    List<double>? persp,
  }) {
    return _method.invokeMethod<void>('applyCrop', {
      'viewId': viewId,
      'rect': {
        'x': rect.x,
        'y': rect.y,
        'w': rect.w,
        'h': rect.h,
      },
      'rotationDeg': rotationDeg,
      if (persp != null) 'persp': persp,
    });
  }

  Future<void> brushStroke({
    required int viewId,
    required List<List<double>> points,
    required int color,
    required double size,
    required double hardness,
  }) {
    return _method.invokeMethod<void>('brushStroke', {
      'viewId': viewId,
      'points': points,
      'color': color,
      'size': size,
      'hardness': hardness,
    });
  }

  Future<void> spotHeal({
    required int viewId,
    required double x,
    required double y,
    required double radius,
  }) {
    return _method.invokeMethod<void>('spotHeal', {
      'viewId': viewId,
      'x': x,
      'y': y,
      'radius': radius,
    });
  }

  Future<void> liquify({
    required int viewId,
    required List<Map<String, dynamic>> ops,
  }) {
    return _method.invokeMethod<void>('liquify', {
      'viewId': viewId,
      'ops': ops,
    });
  }

  Future<void> beautify({
    required int viewId,
    double skin = 0,
    double teeth = 0,
    double eyes = 0,
  }) {
    return _method.invokeMethod<void>('beautify', {
      'viewId': viewId,
      'skin': skin,
      'teeth': teeth,
      'eyes': eyes,
    });
  }

  Future<int> removeBg({required int viewId}) async {
    final res = await _method.invokeMapMethod<String, dynamic>('removeBg', {
      'viewId': viewId,
    });
    return (res?['maskLayerId'] as num?)?.toInt() ?? -1;
  }

  Future<int> placeText({
    required int viewId,
    required String text,
    required String font,
    required double size,
    required int color,
    required MinisImageTransform transform,
  }) async {
    final res = await _method.invokeMapMethod<String, dynamic>('placeText', {
      'viewId': viewId,
      'text': text,
      'font': font,
      'size': size,
      'color': color,
      'transform': transform.toJson(),
    });
    return (res?['layerId'] as num?)?.toInt() ?? -1;
  }

  Future<int> placeSticker({
    required int viewId,
    required String assetId,
    required MinisImageTransform transform,
  }) async {
    final res =
        await _method.invokeMapMethod<String, dynamic>('placeSticker', {
      'viewId': viewId,
      'assetId': assetId,
      'transform': transform.toJson(),
    });
    return (res?['layerId'] as num?)?.toInt() ?? -1;
  }

  Future<int> placeEmoji({
    required int viewId,
    required String codePoint,
    required MinisImageTransform transform,
  }) async {
    final res = await _method.invokeMapMethod<String, dynamic>('placeEmoji', {
      'viewId': viewId,
      'codePoint': codePoint,
      'transform': transform.toJson(),
    });
    return (res?['layerId'] as num?)?.toInt() ?? -1;
  }

  Future<MinisImageUndoState> undo({required int viewId}) async {
    final res = await _method.invokeMapMethod<String, dynamic>('undo', {
      'viewId': viewId,
    });
    return MinisImageUndoState.fromJson(res ?? const {});
  }

  Future<MinisImageUndoState> redo({required int viewId}) async {
    final res = await _method.invokeMapMethod<String, dynamic>('redo', {
      'viewId': viewId,
    });
    return MinisImageUndoState.fromJson(res ?? const {});
  }

  Future<MinisImageExportResult> exportImage({
    required int viewId,
    required MinisImageExportFormat format,
    required int quality,
    int? maxDim,
    required String path,
  }) async {
    final res = await _method.invokeMapMethod<String, dynamic>('exportImage', {
      'viewId': viewId,
      'format': format.wireName,
      'quality': quality,
      if (maxDim != null) 'maxDim': maxDim,
      'path': path,
    });
    if (res == null) {
      throw const MinisImageEditException('exportImage returned null');
    }
    return MinisImageExportResult.fromJson(res);
  }

  Future<List<MinisImageFilterDescriptor>> listFilters() async {
    final res = await _method.invokeMapMethod<String, dynamic>('listFilters');
    final list = (res?['filters'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => MinisImageFilterDescriptor.fromJson(
            m.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<List<MinisImageStickerPack>> listStickerPacks() async {
    final res =
        await _method.invokeMapMethod<String, dynamic>('listStickerPacks');
    final list = (res?['packs'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map(
            (m) => MinisImageStickerPack.fromJson(m.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<List<String>> listFonts() async {
    final res = await _method.invokeMapMethod<String, dynamic>('listFonts');
    final list = (res?['fonts'] as List?) ?? const [];
    return list.whereType<String>().toList(growable: false);
  }
}

/// Returned by `init`. Mirrors the native side's session handle.
class MinisImageEditSession {
  const MinisImageEditSession({
    required this.viewId,
    required this.width,
    required this.height,
    required this.exif,
  });

  factory MinisImageEditSession.fromJson(Map<String, dynamic> m) {
    final exifRaw = m['exif'];
    final Map<String, dynamic> exif = exifRaw is Map
        ? exifRaw.cast<String, dynamic>()
        : const <String, dynamic>{};
    return MinisImageEditSession(
      viewId: (m['viewId'] as num?)?.toInt() ?? 0,
      width: (m['w'] as num?)?.toInt() ?? 0,
      height: (m['h'] as num?)?.toInt() ?? 0,
      exif: exif,
    );
  }

  final int viewId;
  final int width;
  final int height;
  final Map<String, dynamic> exif;
}

class MinisImageUndoState {
  const MinisImageUndoState({required this.canUndo, required this.canRedo});

  factory MinisImageUndoState.fromJson(Map<String, dynamic> m) =>
      MinisImageUndoState(
        canUndo: m['canUndo'] as bool? ?? false,
        canRedo: m['canRedo'] as bool? ?? false,
      );

  final bool canUndo;
  final bool canRedo;
}

class MinisImageExportResult {
  const MinisImageExportResult({
    required this.path,
    required this.width,
    required this.height,
    required this.size,
  });

  factory MinisImageExportResult.fromJson(Map<String, dynamic> m) =>
      MinisImageExportResult(
        path: m['path'] as String? ?? '',
        width: (m['w'] as num?)?.toInt() ?? 0,
        height: (m['h'] as num?)?.toInt() ?? 0,
        size: (m['size'] as num?)?.toInt() ?? 0,
      );

  final String path;
  final int width;
  final int height;
  final int size;
}

class MinisImageFilterDescriptor {
  const MinisImageFilterDescriptor({
    required this.id,
    required this.label,
    required this.lutPath,
  });

  factory MinisImageFilterDescriptor.fromJson(Map<String, dynamic> m) =>
      MinisImageFilterDescriptor(
        id: m['id'] as String? ?? '',
        label: m['label'] as String? ?? '',
        lutPath: m['lutPath'] as String? ?? '',
      );

  final String id;
  final String label;
  final String lutPath;
}

class MinisImageStickerPack {
  const MinisImageStickerPack({
    required this.id,
    required this.label,
    required this.stickers,
  });

  factory MinisImageStickerPack.fromJson(Map<String, dynamic> m) {
    final raw = m['stickers'];
    final list = raw is List
        ? raw
            .whereType<String>()
            .toList(growable: false)
        : const <String>[];
    return MinisImageStickerPack(
      id: m['id'] as String? ?? '',
      label: m['label'] as String? ?? '',
      stickers: list,
    );
  }

  final String id;
  final String label;
  final List<String> stickers;
}

class MinisImageEditEvent {
  const MinisImageEditEvent({
    required this.kind,
    required this.payload,
  });

  factory MinisImageEditEvent.fromJson(Map<String, dynamic> m) =>
      MinisImageEditEvent(
        kind: m['kind'] as String? ?? 'unknown',
        payload: m,
      );

  final String kind;
  final Map<String, dynamic> payload;
}

class MinisImageEditException implements Exception {
  const MinisImageEditException(this.message);
  final String message;
  @override
  String toString() => 'MinisImageEditException: $message';
}

/// Lightweight rect — kept local so callers don't have to depend on
/// `dart:ui` for a value type used purely as channel payload.
class Rect {
  const Rect(this.x, this.y, this.w, this.h);
  final double x;
  final double y;
  final double w;
  final double h;
}

/// Used by [MinisImageEditChannel.init] when the native side is unable to
/// return image bytes (e.g. asset still loading); allows the host to push
/// raw bytes once decoded.
extension MinisImageEditChannelInitBytes on MinisImageEditChannel {
  Future<MinisImageEditSession> initFromBytes({
    required Uint8List bytes,
    required String hintPath,
  }) async {
    final res = await MinisImageEditChannel._method
        .invokeMapMethod<String, dynamic>('init', {
      'sourceBytes': bytes,
      'sourcePath': hintPath,
    });
    if (res == null) {
      throw const MinisImageEditException('init(bytes) returned null');
    }
    return MinisImageEditSession.fromJson(res);
  }
}
