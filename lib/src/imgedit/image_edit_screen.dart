import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:loopit_minis/src/sys/paths.dart';

import 'image_edit_channel.dart';
import 'image_edit_editor_state.dart';
import 'image_edit_filters.dart';
import 'image_edit_layer_types.dart';
import 'image_edit_overlay.dart';
import 'image_edit_panels.dart';
import 'image_edit_theme.dart';
import 'image_edit_view.dart';

/// Full-screen editor route. Hosts the native render surface, a
/// Flutter overlay layer for text/sticker/emoji/draw, and a bottom
/// dock with crop / adjust / filters / decorate tools. All ops route
/// through `MinisImageEditChannel`; the native side processes them for
/// the final export, while the Dart layer keeps the preview live.
class MinisImageEditScreen extends StatefulWidget {
  const MinisImageEditScreen({
    super.key,
    required this.sourcePath,
    this.fallbackBytes,
    this.exportFormat = MinisImageExportFormat.jpeg,
    this.exportQuality = 92,
    this.exportMaxDim,
    this.title = 'Edit',
  });

  static Future<String?> openFromFile(
    BuildContext context,
    String imagePath, {
    MinisImageExportFormat format = MinisImageExportFormat.jpeg,
    int quality = 92,
    int? maxDim,
  }) {
    final file = File(imagePath);
    if (!file.existsSync()) return Future.value(null);
    return Navigator.of(context, rootNavigator: true).push<String?>(
      MaterialPageRoute<String?>(
        fullscreenDialog: true,
        builder: (_) => MinisImageEditScreen(
          sourcePath: imagePath,
          exportFormat: format,
          exportQuality: quality,
          exportMaxDim: maxDim,
        ),
      ),
    );
  }

  static Future<String?> openFromMemory(
    BuildContext context,
    Uint8List bytes, {
    MinisImageExportFormat format = MinisImageExportFormat.jpeg,
    int quality = 92,
    int? maxDim,
  }) async {
    final dirPath = await NativePaths.cacheDir();
    if (dirPath == null) return null;
    final path = NativePaths.join([
      dirPath,
      'minis_imgedit_src_${DateTime.now().microsecondsSinceEpoch}.png',
    ]);
    await File(path).writeAsBytes(bytes, flush: true);
    if (!context.mounted) return null;
    return Navigator.of(context, rootNavigator: true).push<String?>(
      MaterialPageRoute<String?>(
        fullscreenDialog: true,
        builder: (_) => MinisImageEditScreen(
          sourcePath: path,
          fallbackBytes: bytes,
          exportFormat: format,
          exportQuality: quality,
          exportMaxDim: maxDim,
        ),
      ),
    );
  }

  final String sourcePath;
  final Uint8List? fallbackBytes;
  final MinisImageExportFormat exportFormat;
  final int exportQuality;
  final int? exportMaxDim;
  final String title;

  @override
  State<MinisImageEditScreen> createState() => _MinisImageEditScreenState();
}

class _MinisImageEditScreenState extends State<MinisImageEditScreen> {
  final MinisImageEditChannel _channel = MinisImageEditChannel.instance;
  final MinisImageEditEditorState _state = MinisImageEditEditorState();
  int? _viewId;
  bool _busy = false;
  StreamSubscription<MinisImageEditEvent>? _stateSub;
  Timer? _adjustDebounce;
  Timer? _filterDebounce;
  List<String> _fonts = const ['System'];
  late MinisImageEditExportOptions _exportOptions;

  @override
  void initState() {
    super.initState();
    _exportOptions = MinisImageEditExportOptions(
      format: widget.exportFormat,
      quality: widget.exportQuality,
      maxDim: widget.exportMaxDim,
    );
    _stateSub = _channel.events.listen((_) {
      if (!mounted) return;
      setState(() {});
    }, onError: (_) {});
    _state.addListener(_onStateChanged);
    unawaited(_preloadCatalogs());
  }

  Future<void> _preloadCatalogs() async {
    try {
      final fonts = await _channel.listFonts();
      if (!mounted) return;
      if (fonts.isNotEmpty) {
        setState(() => _fonts = ['System', ...fonts]);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _adjustDebounce?.cancel();
    _filterDebounce?.cancel();
    _state.removeListener(_onStateChanged);
    _stateSub?.cancel();
    final id = _viewId;
    if (id != null) {
      unawaited(_channel.dispose(viewId: id));
    }
    _state.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _onPlatformViewCreated(int id) async {
    try {
      final session = await _channel.init(sourcePath: widget.sourcePath);
      if (!mounted) return;
      setState(() => _viewId = session.viewId);
    } catch (_) {
      if (!mounted) return;
      setState(() => _viewId = id);
    }
  }

  // ---------- channel helpers ----------

  Future<void> _undo() async {
    final id = _viewId;
    if (id == null) return;
    try {
      final s = await _channel.undo(viewId: id);
      _state.setUndoState(canUndo: s.canUndo, canRedo: s.canRedo);
    } catch (_) {}
  }

  Future<void> _redo() async {
    final id = _viewId;
    if (id == null) return;
    try {
      final s = await _channel.redo(viewId: id);
      _state.setUndoState(canUndo: s.canUndo, canRedo: s.canRedo);
    } catch (_) {}
  }

  void _applyAdjust(String key, double value) {
    _state.setAdjust(key, value);
    _adjustDebounce?.cancel();
    _adjustDebounce = Timer(const Duration(milliseconds: 40), () async {
      final id = _viewId;
      if (id == null) return;
      try {
        await _channel.applyAdjust(viewId: id, key: key, value: value);
        _state.setUndoState(canUndo: true, canRedo: false);
      } catch (_) {}
    });
  }

  void _pickFilter(MinisImageEditFilter f) {
    _state.setFilter(f);
    _scheduleFilterPush();
  }

  void _setFilterIntensity(double v) {
    _state.filterIntensity = v;
    _scheduleFilterPush();
  }

  void _scheduleFilterPush() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 60), () async {
      final id = _viewId;
      if (id == null) return;
      try {
        await _channel.applyFilter(
          viewId: id,
          lutPath: _state.filter.id,
          intensity: _state.filterIntensity,
        );
        _state.setUndoState(canUndo: true, canRedo: false);
      } catch (_) {}
    });
  }

  Future<void> _applyCrop() async {
    final id = _viewId;
    if (id == null) return;
    final r = _state.cropRect ?? const ui.Rect.fromLTWH(0, 0, 1, 1);
    try {
      await _channel.applyCrop(
        viewId: id,
        rect: Rect(r.left, r.top, r.width, r.height),
        rotationDeg: _state.rotation + _state.straighten,
      );
      _state.setUndoState(canUndo: true, canRedo: false);
    } catch (_) {}
  }

  void _resetCrop() {
    _state.cropRect = null;
    _state.rotation = 0;
    _state.straighten = 0;
    _state.flipH = false;
    _state.flipV = false;
    _state.aspect = MinisImageEditAspect.free;
  }

  Future<void> _addTextOverlay() async {
    final id = _viewId;
    if (id == null) return;
    final res = await showModalBottomSheet<MinisImageEditTextResult>(
      context: context,
      backgroundColor: MinisImageEditTheme.bg,
      isScrollControlled: true,
      builder: (_) => MinisImageEditTextSheet(
        channel: _channel,
        fonts: _fonts,
      ),
    );
    if (res == null) return;
    const transform = MinisImageTransform(
      tx: 0.5, ty: 0.4, scale: 1.0, rotationDeg: 0,
    );
    int layerId;
    try {
      layerId = await _channel.placeText(
        viewId: id,
        text: res.text,
        font: res.font,
        size: res.size,
        color: res.color,
        transform: transform,
      );
    } catch (_) {
      layerId = -DateTime.now().microsecondsSinceEpoch;
    }
    _state.addOverlay(MinisImageEditOverlay(
      id: layerId,
      kind: MinisImageLayerType.text,
      transform: transform,
      text: res.text,
      fontFamily: res.font,
      fontSize: res.size,
      color: res.color,
      background: res.background,
      align: res.align,
    ));
    _state.setUndoState(canUndo: true, canRedo: false);
  }

  Future<void> _addEmojiOverlay() async {
    final id = _viewId;
    if (id == null) return;
    final cp = await showImageEditEmojiSheet(context);
    if (cp == null) return;
    const transform = MinisImageTransform(tx: 0.5, ty: 0.5);
    int layerId;
    try {
      layerId = await _channel.placeEmoji(
        viewId: id,
        codePoint: cp.toString(),
        transform: transform,
      );
    } catch (_) {
      layerId = -DateTime.now().microsecondsSinceEpoch;
    }
    _state.addOverlay(MinisImageEditOverlay(
      id: layerId,
      kind: MinisImageLayerType.emoji,
      transform: transform,
      codePoint: cp.toString(),
    ));
    _state.setUndoState(canUndo: true, canRedo: false);
  }

  Future<void> _addStickerOverlay() async {
    final id = _viewId;
    if (id == null) return;
    final asset = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MinisImageEditTheme.bg,
      isScrollControlled: true,
      builder: (_) => MinisImageEditStickerSheet(channel: _channel),
    );
    if (asset == null) return;
    const transform = MinisImageTransform(tx: 0.5, ty: 0.5);
    int layerId;
    try {
      layerId = await _channel.placeSticker(
        viewId: id,
        assetId: asset,
        transform: transform,
      );
    } catch (_) {
      layerId = -DateTime.now().microsecondsSinceEpoch;
    }
    _state.addOverlay(MinisImageEditOverlay(
      id: layerId,
      kind: MinisImageLayerType.sticker,
      transform: transform,
      assetId: asset,
    ));
    _state.setUndoState(canUndo: true, canRedo: false);
  }

  void _onOverlayTap(int id) {
    _state.selectedOverlay = id;
  }

  void _onOverlayTransform(int id, MinisImageTransform t) {
    final i = _state.overlays.indexWhere((o) => o.id == id);
    if (i < 0) return;
    _state.replaceOverlay(_state.overlays[i].copyWith(transform: t));
  }

  Future<void> _onOverlayCommit(int id, MinisImageTransform t) async {
    final viewId = _viewId;
    if (viewId == null || id < 0) return;
    try {
      await _channel.updateLayer(
        viewId: viewId,
        layerId: id,
        params: {'transform': t.toJson()},
      );
      _state.setUndoState(canUndo: true, canRedo: false);
    } catch (_) {}
  }

  Future<void> _onOverlayDelete(int id) async {
    _state.removeOverlay(id);
    final viewId = _viewId;
    if (viewId == null || id < 0) return;
    try {
      await _channel.removeLayer(viewId: viewId, layerId: id);
      _state.setUndoState(canUndo: true, canRedo: false);
    } catch (_) {}
  }

  void _setBeautify(String key, double v) {
    switch (key) {
      case 'skin':
        _state.beautifySkin = v;
        break;
      case 'teeth':
        _state.beautifyTeeth = v;
        break;
      case 'eyes':
        _state.beautifyEyes = v;
        break;
    }
    _adjustDebounce?.cancel();
    _adjustDebounce = Timer(const Duration(milliseconds: 60), () async {
      final id = _viewId;
      if (id == null) return;
      try {
        await _channel.beautify(
          viewId: id,
          skin: _state.beautifySkin,
          teeth: _state.beautifyTeeth,
          eyes: _state.beautifyEyes,
        );
        _state.setUndoState(canUndo: true, canRedo: false);
      } catch (_) {}
    });
  }

  Future<void> _removeBackground() async {
    final id = _viewId;
    if (id == null) return;
    try {
      await _channel.removeBg(viewId: id);
      _state.removedBg = true;
      _state.setUndoState(canUndo: true, canRedo: false);
    } catch (_) {}
  }

  Future<void> _applyLiquifyPreset(String preset) async {
    final id = _viewId;
    if (id == null) return;
    final ops = <Map<String, dynamic>>[
      {'kind': preset, 'amount': 0.5}
    ];
    try {
      await _channel.liquify(viewId: id, ops: ops);
      _state.setUndoState(canUndo: true, canRedo: false);
    } catch (_) {}
  }

  Future<void> _spotHealAt(Offset normalized) async {
    final id = _viewId;
    if (id == null) return;
    try {
      await _channel.spotHeal(
        viewId: id,
        x: normalized.dx,
        y: normalized.dy,
        radius: _state.healRadius,
      );
      _state.setUndoState(canUndo: true, canRedo: false);
    } catch (_) {}
  }

  Future<void> _onBrushStroke(List<Offset> points) async {
    final id = _viewId;
    if (id == null || points.isEmpty) return;
    final payload = points.map((p) => [p.dx, p.dy]).toList(growable: false);
    try {
      await _channel.brushStroke(
        viewId: id,
        points: payload,
        color: _state.brushEraser ? 0 : _state.brushColor,
        size: _state.brushSize,
        hardness: _state.brushHardness,
      );
      _state.setUndoState(canUndo: true, canRedo: false);
    } catch (_) {}
  }

  // ---------- save / cancel ----------

  Future<String> _passthroughExportPath() async {
    final basePath = await NativePaths.documentsDir();
    if (basePath == null) return widget.sourcePath;
    final dir = Directory(
        NativePaths.join([basePath, 'loopit_minis_captures']));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final out = NativePaths.join([
      dir.path,
      'minis_imgedit_${DateTime.now().microsecondsSinceEpoch}.'
      '${_exportOptions.format.fileExtension}',
    ]);
    final bytes = widget.fallbackBytes;
    if (bytes != null) {
      await File(out).writeAsBytes(bytes, flush: true);
    } else {
      final src = File(widget.sourcePath);
      if (src.existsSync()) {
        await src.copy(out);
      } else {
        return widget.sourcePath;
      }
    }
    return out;
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    final id = _viewId;
    String? outPath;
    if (id != null) {
      try {
        final target = await _passthroughExportPath();
        final res = await _channel.exportImage(
          viewId: id,
          format: _exportOptions.format,
          quality: _exportOptions.quality,
          maxDim: _exportOptions.maxDim,
          path: target,
        );
        outPath = res.path.isNotEmpty ? res.path : target;
      } catch (_) {
        outPath = null;
      }
    }
    outPath ??= await _passthroughExportPath();
    if (!mounted) return;
    Navigator.of(context).pop(outPath);
  }

  Future<void> _openExportOptions() async {
    final res = await showModalBottomSheet<MinisImageEditExportOptions>(
      context: context,
      backgroundColor: MinisImageEditTheme.bg,
      isScrollControlled: true,
      builder: (_) => MinisImageEditExportSheet(initial: _exportOptions),
    );
    if (res != null) {
      setState(() => _exportOptions = res);
    }
  }

  Future<void> _openLayersSheet() async {
    if (_state.overlays.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: MinisImageEditTheme.bg,
      isScrollControlled: true,
      builder: (_) => MinisImageEditLayersSheet(
        state: _state,
        onDelete: _onOverlayDelete,
        onSelect: (id) => _state.selectedOverlay = id,
      ),
    );
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: MinisImageEditTheme.bg,
        appBar: _buildAppBar(),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: _buildCanvas()),
              _buildBottom(),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: MinisImageEditTheme.bg,
      foregroundColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _busy ? null : _cancel,
      ),
      title: Text(widget.title),
      actions: [
        IconButton(
          tooltip: 'Layers',
          icon: const Icon(Icons.layers_outlined),
          onPressed: _state.overlays.isEmpty || _busy ? null : _openLayersSheet,
        ),
        IconButton(
          tooltip: 'Undo',
          icon: const Icon(Icons.undo),
          onPressed: _state.canUndo && !_busy ? _undo : null,
        ),
        IconButton(
          tooltip: 'Redo',
          icon: const Icon(Icons.redo),
          onPressed: _state.canRedo && !_busy ? _redo : null,
        ),
        GestureDetector(
          onLongPress: _busy ? null : _openExportOptions,
          child: TextButton(
            style: TextButton.styleFrom(
              foregroundColor: MinisImageEditTheme.accent,
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: MinisImageEditTheme.accent,
                    ),
                  )
                : const Text(
                    'Save',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildCanvas() {
    final preview = buildImageEditPreviewFilter(
      filter: _state.filter,
      intensity: _state.filterIntensity,
      adjust: _state.adjust,
    );
    final canvas = Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..scaleByDouble(
          _state.flipH ? -1.0 : 1.0,
          _state.flipV ? -1.0 : 1.0,
          1.0,
          1.0,
        )
        ..rotateZ((_state.rotation + _state.straighten) * 3.1415926 / 180.0),
      child: ColorFiltered(
        colorFilter: preview,
        child: MinisImageEditPlatformView(
          sourcePath: widget.sourcePath,
          onPlatformViewCreated: _onPlatformViewCreated,
        ),
      ),
    );

    final cropping = _state.tab == MinisImageEditTab.crop;
    final drawing = _state.tab == MinisImageEditTab.decorate &&
        _state.decorateTool == MinisImageEditDecorateTool.draw;
    final healing = _state.tab == MinisImageEditTab.retouch &&
        _state.retouchTool == MinisImageEditRetouchTool.heal;

    return Stack(
      fit: StackFit.expand,
      children: [
        canvas,
        if (_viewId == null)
          const Center(
            child: CircularProgressIndicator(color: Colors.white70),
          ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: cropping || drawing || healing,
            child: MinisImageEditOverlayStack(
              state: _state,
              onTap: _onOverlayTap,
              onTransform: _onOverlayTransform,
              onCommit: _onOverlayCommit,
              onDelete: _onOverlayDelete,
            ),
          ),
        ),
        Positioned.fill(
          child: MinisImageEditBrushOverlay(
            state: _state,
            enabled: drawing,
            onStroke: _onBrushStroke,
          ),
        ),
        Positioned.fill(
          child: MinisImageEditCropOverlay(
            state: _state,
            enabled: cropping,
          ),
        ),
        if (healing)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (_, c) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  final w = c.maxWidth;
                  final h = c.maxHeight;
                  if (w == 0 || h == 0) return;
                  unawaited(_spotHealAt(Offset(
                    d.localPosition.dx / w,
                    d.localPosition.dy / h,
                  )));
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottom() {
    return Container(
      color: MinisImageEditTheme.bg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildActivePanel(),
          _buildDock(),
        ],
      ),
    );
  }

  Widget _buildActivePanel() {
    switch (_state.tab) {
      case MinisImageEditTab.crop:
        return MinisImageEditCropPanel(
          state: _state,
          onApply: () async {
            await _applyCrop();
          },
          onReset: _resetCrop,
          onRotate: (deg) {
            _state.rotation = (_state.rotation + deg) % 360;
          },
          onFlipH: () => _state.flipH = !_state.flipH,
          onFlipV: () => _state.flipV = !_state.flipV,
          onStraighten: (v) => _state.straighten = v,
          onAspect: (a) {
            _state.aspect = a;
            final r = a.ratio;
            if (r != null) {
              // Re-anchor the crop rect to the aspect ratio while
              // staying centered. Use the larger of the two dimensions
              // so we don't blow past the source on tall ratios.
              final cur = _state.cropRect ??
                  const ui.Rect.fromLTWH(0.05, 0.05, 0.9, 0.9);
              final cx = cur.left + cur.width / 2;
              final cy = cur.top + cur.height / 2;
              final w = cur.width;
              final h = w / r;
              final clampedH = h.clamp(0.1, 0.95).toDouble();
              final clampedW = (clampedH * r).clamp(0.1, 0.95).toDouble();
              final left = (cx - clampedW / 2).clamp(0.0, 1.0 - clampedW);
              final top = (cy - clampedH / 2).clamp(0.0, 1.0 - clampedH);
              _state.cropRect = ui.Rect.fromLTWH(left, top, clampedW, clampedH);
            }
          },
        );
      case MinisImageEditTab.adjust:
        return MinisImageEditAdjustPanel(
          state: _state,
          onChanged: _applyAdjust,
          onReset: () {
            _state.resetAdjust();
            final id = _viewId;
            if (id == null) return;
            for (final e in MinisImageEditAdjustKey.all) {
              unawaited(_channel.applyAdjust(
                viewId: id,
                key: e.key,
                value: 0,
              ).catchError((_) {}));
            }
          },
        );
      case MinisImageEditTab.filter:
        return MinisImageEditFilterPanel(
          state: _state,
          sourceFile: File(widget.sourcePath),
          onPick: _pickFilter,
          onIntensity: _setFilterIntensity,
          onReset: () {
            _pickFilter(MinisImageEditFilter.none);
          },
        );
      case MinisImageEditTab.decorate:
        return MinisImageEditDecoratePanel(
          state: _state,
          viewId: _viewId,
          onChangeTool: (t) => _state.decorateTool = t,
          onAddText: _addTextOverlay,
          onOpenEmoji: _addEmojiOverlay,
          onPickSticker: _addStickerOverlay,
        );
      case MinisImageEditTab.retouch:
        return MinisImageEditRetouchPanel(
          state: _state,
          onChangeTool: (t) => _state.retouchTool = t,
          onBeautifyChanged: _setBeautify,
          onRemoveBg: _removeBackground,
          onLiquifyPreset: _applyLiquifyPreset,
        );
    }
  }

  Widget _buildDock() {
    const tabs = MinisImageEditTab.values;
    const icons = <IconData>[
      Icons.crop,
      Icons.tune,
      Icons.auto_awesome,
      Icons.layers_outlined,
      Icons.face_retouching_natural,
    ];
    return Container(
      height: 72,
      decoration: const BoxDecoration(
        color: MinisImageEditTheme.bg,
        border: Border(
          top: BorderSide(color: MinisImageEditTheme.divider, width: 1),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _state.tab = tabs[i],
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icons[i],
                      size: 22,
                      color: _state.tab == tabs[i]
                          ? MinisImageEditTheme.accent
                          : Colors.white70,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tabs[i].label,
                      style: TextStyle(
                        fontSize: 11,
                        color: _state.tab == tabs[i]
                            ? MinisImageEditTheme.accent
                            : Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
