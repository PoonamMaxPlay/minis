import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'image_edit_layer_types.dart';
import 'image_edit_theme.dart';

/// Bottom-dock tab. The screen renders the matching panel below the
/// canvas; switching tabs leaves canvas state untouched.
enum MinisImageEditTab { crop, adjust, filter, decorate, retouch }

extension MinisImageEditTabMeta on MinisImageEditTab {
  String get label {
    switch (this) {
      case MinisImageEditTab.crop:
        return 'Crop';
      case MinisImageEditTab.adjust:
        return 'Adjust';
      case MinisImageEditTab.filter:
        return 'Filters';
      case MinisImageEditTab.decorate:
        return 'Decorate';
      case MinisImageEditTab.retouch:
        return 'Retouch';
    }
  }
}

/// Sub-tool under the Retouch tab.
enum MinisImageEditRetouchTool { beautify, heal, liquify, removeBg }

/// Sub-tool under the Decorate tab.
enum MinisImageEditDecorateTool { text, sticker, emoji, draw }

/// In-memory representation of a Dart-side overlay layer. The native
/// pipeline owns the source-of-truth layer stack — these objects exist
/// so the Flutter overlay can render handles, selection, and gestures
/// without round-tripping the channel on every frame.
@immutable
class MinisImageEditOverlay {
  const MinisImageEditOverlay({
    required this.id,
    required this.kind,
    required this.transform,
    this.text,
    this.fontFamily,
    this.fontSize,
    this.color,
    this.background,
    this.align,
    this.assetId,
    this.codePoint,
  });

  final int id;
  final MinisImageLayerType kind;
  final MinisImageTransform transform;
  final String? text;
  final String? fontFamily;
  final double? fontSize;
  final int? color;
  final int? background;
  final String? align;
  final String? assetId;
  final String? codePoint;

  MinisImageEditOverlay copyWith({
    MinisImageTransform? transform,
    String? text,
    String? fontFamily,
    double? fontSize,
    int? color,
    int? background,
    String? align,
  }) {
    return MinisImageEditOverlay(
      id: id,
      kind: kind,
      transform: transform ?? this.transform,
      text: text ?? this.text,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      color: color ?? this.color,
      background: background ?? this.background,
      align: align ?? this.align,
      assetId: assetId,
      codePoint: codePoint,
    );
  }
}

/// All UI-side state for the editor screen. Mutated through the
/// notifier; the screen + panels listen to a single source.
class MinisImageEditEditorState extends ChangeNotifier {
  MinisImageEditEditorState();

  // --- Tab / mode ---
  MinisImageEditTab _tab = MinisImageEditTab.adjust;
  MinisImageEditTab get tab => _tab;
  set tab(MinisImageEditTab v) {
    if (_tab == v) return;
    _tab = v;
    notifyListeners();
  }

  MinisImageEditDecorateTool _decorateTool = MinisImageEditDecorateTool.text;
  MinisImageEditDecorateTool get decorateTool => _decorateTool;
  set decorateTool(MinisImageEditDecorateTool v) {
    if (_decorateTool == v) return;
    _decorateTool = v;
    notifyListeners();
  }

  MinisImageEditRetouchTool _retouchTool = MinisImageEditRetouchTool.beautify;
  MinisImageEditRetouchTool get retouchTool => _retouchTool;
  set retouchTool(MinisImageEditRetouchTool v) {
    if (_retouchTool == v) return;
    _retouchTool = v;
    notifyListeners();
  }

  // --- Retouch (beautify + heal) ---
  double _beautifySkin = 0;
  double get beautifySkin => _beautifySkin;
  set beautifySkin(double v) {
    _beautifySkin = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  double _beautifyTeeth = 0;
  double get beautifyTeeth => _beautifyTeeth;
  set beautifyTeeth(double v) {
    _beautifyTeeth = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  double _beautifyEyes = 0;
  double get beautifyEyes => _beautifyEyes;
  set beautifyEyes(double v) {
    _beautifyEyes = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  double _healRadius = 24.0;
  double get healRadius => _healRadius;
  set healRadius(double v) {
    _healRadius = v.clamp(4.0, 96.0);
    notifyListeners();
  }

  bool _removedBg = false;
  bool get removedBg => _removedBg;
  set removedBg(bool v) {
    _removedBg = v;
    notifyListeners();
  }

  // --- Crop ---
  MinisImageEditAspect _aspect = MinisImageEditAspect.free;
  MinisImageEditAspect get aspect => _aspect;
  set aspect(MinisImageEditAspect v) {
    _aspect = v;
    notifyListeners();
  }

  double _rotation = 0; // degrees, multiples of 90 for tap-rotate
  double get rotation => _rotation;
  set rotation(double v) {
    _rotation = v;
    notifyListeners();
  }

  double _straighten = 0; // degrees, -45..45
  double get straighten => _straighten;
  set straighten(double v) {
    _straighten = v.clamp(-45.0, 45.0);
    notifyListeners();
  }

  bool _flipH = false;
  bool get flipH => _flipH;
  set flipH(bool v) {
    _flipH = v;
    notifyListeners();
  }

  bool _flipV = false;
  bool get flipV => _flipV;
  set flipV(bool v) {
    _flipV = v;
    notifyListeners();
  }

  /// Normalized crop rect (0..1) inside the source image. `null` ==
  /// full image. Edited via the crop panel overlay.
  ui.Rect? _cropRect;
  ui.Rect? get cropRect => _cropRect;
  set cropRect(ui.Rect? v) {
    _cropRect = v;
    notifyListeners();
  }

  // --- Adjust ---
  final Map<String, double> _adjust = {
    for (final e in MinisImageEditAdjustKey.all) e.key: 0.0,
  };
  Map<String, double> get adjust => Map.unmodifiable(_adjust);
  double adjustValue(String key) => _adjust[key] ?? 0;

  void setAdjust(String key, double v) {
    final clamped = v.clamp(-1.0, 1.0).toDouble();
    if ((_adjust[key] ?? 0) == clamped) return;
    _adjust[key] = clamped;
    notifyListeners();
  }

  void resetAdjust() {
    var changed = false;
    for (final k in _adjust.keys.toList()) {
      if ((_adjust[k] ?? 0) != 0) {
        _adjust[k] = 0;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // --- Filter ---
  MinisImageEditFilter _filter = MinisImageEditFilter.none;
  MinisImageEditFilter get filter => _filter;
  double _filterIntensity = 1.0;
  double get filterIntensity => _filterIntensity;

  void setFilter(MinisImageEditFilter f) {
    if (_filter == f) return;
    _filter = f;
    _filterIntensity = f == MinisImageEditFilter.none ? 0 : 1.0;
    notifyListeners();
  }

  set filterIntensity(double v) {
    final clamped = v.clamp(0.0, 1.0).toDouble();
    if (_filterIntensity == clamped) return;
    _filterIntensity = clamped;
    notifyListeners();
  }

  // --- Overlays (Dart-side mirror of native layer stack) ---
  final List<MinisImageEditOverlay> _overlays = [];
  List<MinisImageEditOverlay> get overlays => List.unmodifiable(_overlays);

  int? _selectedOverlay;
  int? get selectedOverlay => _selectedOverlay;
  set selectedOverlay(int? id) {
    if (_selectedOverlay == id) return;
    _selectedOverlay = id;
    notifyListeners();
  }

  void addOverlay(MinisImageEditOverlay o) {
    _overlays.add(o);
    _selectedOverlay = o.id;
    notifyListeners();
  }

  void replaceOverlay(MinisImageEditOverlay o) {
    final i = _overlays.indexWhere((x) => x.id == o.id);
    if (i < 0) return;
    _overlays[i] = o;
    notifyListeners();
  }

  void removeOverlay(int id) {
    _overlays.removeWhere((o) => o.id == id);
    if (_selectedOverlay == id) _selectedOverlay = null;
    notifyListeners();
  }

  // --- Brush ---
  double _brushSize = 18.0;
  double get brushSize => _brushSize;
  set brushSize(double v) {
    _brushSize = v;
    notifyListeners();
  }

  double _brushHardness = 0.8;
  double get brushHardness => _brushHardness;
  set brushHardness(double v) {
    _brushHardness = v;
    notifyListeners();
  }

  int _brushColor = 0xFFFFFFFF;
  int get brushColor => _brushColor;
  set brushColor(int v) {
    _brushColor = v;
    notifyListeners();
  }

  bool _brushEraser = false;
  bool get brushEraser => _brushEraser;
  set brushEraser(bool v) {
    _brushEraser = v;
    notifyListeners();
  }

  // --- Undo/redo cache (mirrors native canUndo/canRedo) ---
  bool _canUndo = false;
  bool get canUndo => _canUndo;
  bool _canRedo = false;
  bool get canRedo => _canRedo;

  void setUndoState({required bool canUndo, required bool canRedo}) {
    if (_canUndo == canUndo && _canRedo == canRedo) return;
    _canUndo = canUndo;
    _canRedo = canRedo;
    notifyListeners();
  }
}
