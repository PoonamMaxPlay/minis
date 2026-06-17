/// Layer model mirrored by Android `LayerStack.kt` / iOS `LayerStack.swift`.
///
/// Layer params travel as `Map<String, dynamic>` through `MethodChannel`,
/// so each `*Layer` is a thin typed builder over a JSON-shaped map.
library;

enum MinisImageLayerType {
  baseImage,
  adjustment,
  filter,
  sticker,
  text,
  draw,
  mask,
  emoji,
}

extension MinisImageLayerTypeWire on MinisImageLayerType {
  String get wireName {
    switch (this) {
      case MinisImageLayerType.baseImage:
        return 'baseImage';
      case MinisImageLayerType.adjustment:
        return 'adjustment';
      case MinisImageLayerType.filter:
        return 'filter';
      case MinisImageLayerType.sticker:
        return 'sticker';
      case MinisImageLayerType.text:
        return 'text';
      case MinisImageLayerType.draw:
        return 'draw';
      case MinisImageLayerType.mask:
        return 'mask';
      case MinisImageLayerType.emoji:
        return 'emoji';
    }
  }
}

enum MinisImageBlendMode {
  normal,
  multiply,
  screen,
  overlay,
  softLight,
  hardLight,
}

extension MinisImageBlendModeWire on MinisImageBlendMode {
  String get wireName {
    switch (this) {
      case MinisImageBlendMode.normal:
        return 'normal';
      case MinisImageBlendMode.multiply:
        return 'multiply';
      case MinisImageBlendMode.screen:
        return 'screen';
      case MinisImageBlendMode.overlay:
        return 'overlay';
      case MinisImageBlendMode.softLight:
        return 'softLight';
      case MinisImageBlendMode.hardLight:
        return 'hardLight';
    }
  }
}

enum MinisImageExportFormat { jpeg, png, heic, webp }

extension MinisImageExportFormatWire on MinisImageExportFormat {
  String get wireName {
    switch (this) {
      case MinisImageExportFormat.jpeg:
        return 'jpeg';
      case MinisImageExportFormat.png:
        return 'png';
      case MinisImageExportFormat.heic:
        return 'heic';
      case MinisImageExportFormat.webp:
        return 'webp';
    }
  }

  String get fileExtension {
    switch (this) {
      case MinisImageExportFormat.jpeg:
        return 'jpg';
      case MinisImageExportFormat.png:
        return 'png';
      case MinisImageExportFormat.heic:
        return 'heic';
      case MinisImageExportFormat.webp:
        return 'webp';
    }
  }
}

class MinisImageTransform {
  const MinisImageTransform({
    this.tx = 0,
    this.ty = 0,
    this.scale = 1,
    this.rotationDeg = 0,
    this.skewX = 0,
    this.skewY = 0,
  });

  final double tx;
  final double ty;
  final double scale;
  final double rotationDeg;
  final double skewX;
  final double skewY;

  Map<String, dynamic> toJson() => {
        'tx': tx,
        'ty': ty,
        'scale': scale,
        'rotationDeg': rotationDeg,
        'skewX': skewX,
        'skewY': skewY,
      };
}
