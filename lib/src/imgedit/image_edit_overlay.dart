import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'image_edit_editor_state.dart';
import 'image_edit_layer_types.dart';
import 'image_edit_theme.dart';

/// Flutter-side overlay that floats above the native canvas. Hosts
/// text / sticker / emoji widgets for live drag + scale + rotate. The
/// screen mirrors the gesture stream onto the native channel via
/// `updateLayer`. Brush strokes are captured by
/// [MinisImageEditBrushOverlay] in a separate layer above this.
class MinisImageEditOverlayStack extends StatelessWidget {
  const MinisImageEditOverlayStack({
    super.key,
    required this.state,
    required this.onTap,
    required this.onTransform,
    required this.onCommit,
    required this.onDelete,
  });

  final MinisImageEditEditorState state;
  final ValueChanged<int> onTap;
  final void Function(int id, MinisImageTransform t) onTransform;
  final void Function(int id, MinisImageTransform t) onCommit;
  final ValueChanged<int> onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final o in state.overlays)
              _OverlayHandle(
                key: ValueKey(o.id),
                overlay: o,
                selected: state.selectedOverlay == o.id,
                bounds: Size(w, h),
                onTap: () => onTap(o.id),
                onTransform: (t) => onTransform(o.id, t),
                onCommit: (t) => onCommit(o.id, t),
                onDelete: () => onDelete(o.id),
              ),
          ],
        );
      },
    );
  }
}

class _OverlayHandle extends StatefulWidget {
  const _OverlayHandle({
    super.key,
    required this.overlay,
    required this.selected,
    required this.bounds,
    required this.onTap,
    required this.onTransform,
    required this.onCommit,
    required this.onDelete,
  });
  final MinisImageEditOverlay overlay;
  final bool selected;
  final Size bounds;
  final VoidCallback onTap;
  final ValueChanged<MinisImageTransform> onTransform;
  final ValueChanged<MinisImageTransform> onCommit;
  final VoidCallback onDelete;

  @override
  State<_OverlayHandle> createState() => _OverlayHandleState();
}

class _OverlayHandleState extends State<_OverlayHandle> {
  late MinisImageTransform _t;
  double _scaleStart = 1.0;
  double _rotStart = 0.0;
  MinisImageTransform _gestureBase = const MinisImageTransform();
  Offset _focalStart = Offset.zero;

  @override
  void initState() {
    super.initState();
    _t = widget.overlay.transform;
  }

  @override
  void didUpdateWidget(covariant _OverlayHandle old) {
    super.didUpdateWidget(old);
    if (old.overlay.transform != widget.overlay.transform) {
      _t = widget.overlay.transform;
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.bounds.width;
    final h = widget.bounds.height;
    final cx = _t.tx * w;
    final cy = _t.ty * h;
    final size = _intrinsicSize();
    return Positioned(
      left: cx - size.width / 2,
      top: cy - size.height / 2,
      width: size.width,
      height: size.height,
      child: Transform.rotate(
        angle: _t.rotationDeg * 3.1415926 / 180.0,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onScaleStart: (d) {
            _gestureBase = _t;
            _scaleStart = _t.scale;
            _rotStart = _t.rotationDeg;
            _focalStart = d.focalPoint;
          },
          onScaleUpdate: (d) {
            final dx = (d.focalPoint.dx - _focalStart.dx) / w;
            final dy = (d.focalPoint.dy - _focalStart.dy) / h;
            final next = MinisImageTransform(
              tx: (_gestureBase.tx + dx).clamp(0.0, 1.0),
              ty: (_gestureBase.ty + dy).clamp(0.0, 1.0),
              scale: (_scaleStart * d.scale).clamp(0.1, 8.0),
              rotationDeg: _rotStart + d.rotation * 180 / 3.1415926,
            );
            setState(() => _t = next);
            widget.onTransform(next);
          },
          onScaleEnd: (_) => widget.onCommit(_t),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildContent(),
              if (widget.selected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: MinisImageEditTheme.accent,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.selected)
                Positioned(
                  right: -10,
                  top: -10,
                  child: GestureDetector(
                    onTap: widget.onDelete,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: const BoxDecoration(
                        color: MinisImageEditTheme.danger,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Size _intrinsicSize() {
    final scale = _t.scale.clamp(0.1, 8.0);
    switch (widget.overlay.kind) {
      case MinisImageLayerType.text:
        final base = (widget.overlay.fontSize ?? 24) * scale;
        final text = widget.overlay.text ?? '';
        final w = (text.length.clamp(1, 30) * base * 0.55).clamp(40.0, 600.0);
        final lines = '\n'.allMatches(text).length + 1;
        final h = base * lines * 1.4 + 16;
        return Size(w, h);
      case MinisImageLayerType.emoji:
        final size = 56.0 * scale;
        return Size(size, size);
      case MinisImageLayerType.sticker:
        final size = 120.0 * scale;
        return Size(size, size);
      default:
        return Size(80 * scale, 80 * scale);
    }
  }

  Widget _buildContent() {
    final o = widget.overlay;
    switch (o.kind) {
      case MinisImageLayerType.text:
        final bg = o.background ?? 0x00000000;
        return Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Color(bg),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            o.text ?? '',
            textAlign: _toAlign(o.align),
            style: TextStyle(
              color: Color(o.color ?? 0xFFFFFFFF),
              fontSize: (o.fontSize ?? 24) * _t.scale,
              fontFamily: (o.fontFamily == null || o.fontFamily == 'System')
                  ? null
                  : o.fontFamily,
              shadows: const [
                Shadow(
                  blurRadius: 6,
                  color: Colors.black54,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        );
      case MinisImageLayerType.emoji:
        return Center(
          child: Text(
            _emojiFromCodePoint(o.codePoint),
            style: TextStyle(fontSize: 48 * _t.scale),
          ),
        );
      case MinisImageLayerType.sticker:
        return Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.emoji_emotions_outlined,
            color: Colors.white70,
            size: 48,
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  TextAlign _toAlign(String? s) {
    switch (s) {
      case 'left':
        return TextAlign.left;
      case 'right':
        return TextAlign.right;
      default:
        return TextAlign.center;
    }
  }

  String _emojiFromCodePoint(String? cp) {
    if (cp == null) return '';
    final n = int.tryParse(cp);
    if (n == null) return '';
    return String.fromCharCode(n);
  }
}

/// Brush overlay: captures gestures while Decorate→Draw is active.
class MinisImageEditBrushOverlay extends StatefulWidget {
  const MinisImageEditBrushOverlay({
    super.key,
    required this.state,
    required this.enabled,
    required this.onStroke,
  });

  final MinisImageEditEditorState state;
  final bool enabled;
  final void Function(List<Offset> normalizedPoints) onStroke;

  @override
  State<MinisImageEditBrushOverlay> createState() => _BrushOverlayState();
}

class _BrushOverlayState extends State<MinisImageEditBrushOverlay> {
  final List<_Stroke> _strokes = [];
  _Stroke? _current;
  Size _size = Size.zero;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        _size = Size(c.maxWidth, c.maxHeight);
        return IgnorePointer(
          ignoring: !widget.enabled,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) {
              setState(() {
                _current = _Stroke(
                  color: widget.state.brushColor,
                  size: widget.state.brushSize,
                  eraser: widget.state.brushEraser,
                  points: [d.localPosition],
                );
              });
            },
            onPanUpdate: (d) {
              final cur = _current;
              if (cur == null) return;
              setState(() => cur.points.add(d.localPosition));
            },
            onPanEnd: (_) {
              final cur = _current;
              if (cur == null) return;
              _strokes.add(cur);
              _current = null;
              final w = _size.width == 0 ? 1 : _size.width;
              final h = _size.height == 0 ? 1 : _size.height;
              final norm = cur.points
                  .map((p) => Offset(p.dx / w, p.dy / h))
                  .toList(growable: false);
              widget.onStroke(norm);
              setState(() {});
            },
            child: CustomPaint(
              size: Size.infinite,
              painter: _BrushPainter(
                strokes: [..._strokes, if (_current != null) _current!],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Stroke {
  _Stroke({
    required this.color,
    required this.size,
    required this.eraser,
    required this.points,
  });
  final int color;
  final double size;
  final bool eraser;
  final List<Offset> points;
}

class _BrushPainter extends CustomPainter {
  _BrushPainter({required this.strokes});
  final List<_Stroke> strokes;
  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final p = Paint()
        ..color = s.eraser ? const Color(0xFFFFFFFF) : Color(s.color)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.size
        ..blendMode = s.eraser ? BlendMode.clear : BlendMode.srcOver;
      if (s.points.length < 2) {
        if (s.points.isNotEmpty) {
          canvas.drawCircle(s.points.first, s.size / 2,
              p..style = PaintingStyle.fill);
        }
        continue;
      }
      final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
      for (var i = 1; i < s.points.length; i++) {
        path.lineTo(s.points[i].dx, s.points[i].dy);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant _BrushPainter old) => old.strokes != strokes;
}

/// Crop frame overlay — draggable corners + rule-of-thirds grid. Saves
/// its normalized rect into `state.cropRect`; the screen reads it when
/// Apply is pressed on the crop panel and forwards to `applyCrop`.
class MinisImageEditCropOverlay extends StatefulWidget {
  const MinisImageEditCropOverlay({
    super.key,
    required this.state,
    required this.enabled,
  });
  final MinisImageEditEditorState state;
  final bool enabled;
  @override
  State<MinisImageEditCropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<MinisImageEditCropOverlay> {
  ui.Rect _r = const ui.Rect.fromLTWH(0.05, 0.05, 0.9, 0.9);
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    final init = widget.state.cropRect;
    if (init != null) _r = init;
  }

  @override
  void didUpdateWidget(covariant MinisImageEditCropOverlay old) {
    super.didUpdateWidget(old);
    final r = widget.state.cropRect;
    if (r != null && r != _r) _r = r;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (_, c) {
        _size = Size(c.maxWidth, c.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _CropPainter(rect: _r),
              size: Size.infinite,
            ),
            ..._handles(),
          ],
        );
      },
    );
  }

  List<Widget> _handles() {
    final w = _size.width;
    final h = _size.height;
    if (w == 0 || h == 0) return const [];
    final x = _r.left * w;
    final y = _r.top * h;
    final rw = _r.width * w;
    final rh = _r.height * h;
    return [
      _handle(Offset(x, y), (d) => _resize(d, left: true, top: true)),
      _handle(Offset(x + rw, y), (d) => _resize(d, right: true, top: true)),
      _handle(Offset(x, y + rh), (d) => _resize(d, left: true, bottom: true)),
      _handle(Offset(x + rw, y + rh),
          (d) => _resize(d, right: true, bottom: true)),
      Positioned(
        left: x,
        top: y,
        width: rw,
        height: rh,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanUpdate: (d) {
            final dx = d.delta.dx / w;
            final dy = d.delta.dy / h;
            setState(() {
              final nx = (_r.left + dx).clamp(0.0, 1.0 - _r.width);
              final ny = (_r.top + dy).clamp(0.0, 1.0 - _r.height);
              _r = ui.Rect.fromLTWH(nx, ny, _r.width, _r.height);
            });
            widget.state.cropRect = _r;
          },
        ),
      ),
    ];
  }

  Widget _handle(Offset p, void Function(DragUpdateDetails) onDrag) {
    return Positioned(
      left: p.dx - 14,
      top: p.dy - 14,
      width: 28,
      height: 28,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: onDrag,
        child: Container(
          alignment: Alignment.center,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: MinisImageEditTheme.accent,
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  void _resize(
    DragUpdateDetails d, {
    bool left = false,
    bool right = false,
    bool top = false,
    bool bottom = false,
  }) {
    final w = _size.width;
    final h = _size.height;
    if (w == 0 || h == 0) return;
    final dx = d.delta.dx / w;
    final dy = d.delta.dy / h;
    setState(() {
      var x = _r.left;
      var y = _r.top;
      var rw = _r.width;
      var rh = _r.height;
      const minSize = 0.1;
      if (left) {
        final nx = (x + dx).clamp(0.0, x + rw - minSize);
        rw = rw + (x - nx);
        x = nx;
      }
      if (right) {
        rw = (rw + dx).clamp(minSize, 1.0 - x);
      }
      if (top) {
        final ny = (y + dy).clamp(0.0, y + rh - minSize);
        rh = rh + (y - ny);
        y = ny;
      }
      if (bottom) {
        rh = (rh + dy).clamp(minSize, 1.0 - y);
      }
      _r = ui.Rect.fromLTWH(x, y, rw, rh);
    });
    widget.state.cropRect = _r;
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({required this.rect});
  final ui.Rect rect;
  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black54;
    final x = rect.left * size.width;
    final y = rect.top * size.height;
    final w = rect.width * size.width;
    final h = rect.height * size.height;
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, size.width, y), dim);
    canvas.drawRect(
        ui.Rect.fromLTWH(0, y + h, size.width, size.height - y - h), dim);
    canvas.drawRect(ui.Rect.fromLTWH(0, y, x, h), dim);
    canvas.drawRect(
        ui.Rect.fromLTWH(x + w, y, size.width - x - w, h), dim);
    final border = Paint()
      ..color = MinisImageEditTheme.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(ui.Rect.fromLTWH(x, y, w, h), border);
    final grid = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final gx = x + w * i / 3;
      final gy = y + h * i / 3;
      canvas.drawLine(Offset(gx, y), Offset(gx, y + h), grid);
      canvas.drawLine(Offset(x, gy), Offset(x + w, gy), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.rect != rect;
}
