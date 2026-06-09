import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'emoji_picker_view.dart';
import 'image_edit_channel.dart';
import 'image_edit_editor_state.dart';
import 'image_edit_filters.dart';
import 'image_edit_layer_types.dart';
import 'image_edit_theme.dart';

/// ------------- CROP -------------
class MinisImageEditCropPanel extends StatelessWidget {
  const MinisImageEditCropPanel({
    super.key,
    required this.state,
    required this.onApply,
    required this.onRotate,
    required this.onFlipH,
    required this.onFlipV,
    required this.onStraighten,
    required this.onAspect,
    required this.onReset,
  });

  final MinisImageEditEditorState state;
  final VoidCallback onApply;
  final ValueChanged<int> onRotate; // ±90 deg
  final VoidCallback onFlipH;
  final VoidCallback onFlipV;
  final ValueChanged<double> onStraighten;
  final ValueChanged<MinisImageEditAspect> onAspect;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return _PanelShell(
      title: 'Crop & rotate',
      onReset: onReset,
      onApply: onApply,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: MinisImageEditAspect.presets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final a = MinisImageEditAspect.presets[i];
                final sel = state.aspect.label == a.label;
                return _Chip(
                  label: a.label,
                  selected: sel,
                  onTap: () => onAspect(a),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _IconBtn(
                  icon: Icons.rotate_90_degrees_ccw,
                  label: 'Rotate L',
                  onTap: () => onRotate(-90),
                ),
                _IconBtn(
                  icon: Icons.rotate_90_degrees_cw,
                  label: 'Rotate R',
                  onTap: () => onRotate(90),
                ),
                _IconBtn(
                  icon: Icons.flip,
                  label: 'Flip H',
                  selected: state.flipH,
                  onTap: onFlipH,
                ),
                _IconBtn(
                  icon: Icons.flip_camera_android_outlined,
                  label: 'Flip V',
                  selected: state.flipV,
                  onTap: onFlipV,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          _LabeledSlider(
            label: 'Straighten',
            value: state.straighten,
            min: -45,
            max: 45,
            onChanged: onStraighten,
            valueLabel: '${state.straighten.toStringAsFixed(0)}°',
          ),
        ],
      ),
    );
  }
}

/// ------------- ADJUST -------------
class MinisImageEditAdjustPanel extends StatefulWidget {
  const MinisImageEditAdjustPanel({
    super.key,
    required this.state,
    required this.onChanged,
    required this.onReset,
  });

  final MinisImageEditEditorState state;
  final void Function(String key, double value) onChanged;
  final VoidCallback onReset;

  @override
  State<MinisImageEditAdjustPanel> createState() =>
      _MinisImageEditAdjustPanelState();
}

class _MinisImageEditAdjustPanelState extends State<MinisImageEditAdjustPanel> {
  String _key = MinisImageEditAdjustKey.brightness;

  @override
  Widget build(BuildContext context) {
    final entry = MinisImageEditAdjustKey.all.firstWhere(
      (e) => e.key == _key,
      orElse: () => MinisImageEditAdjustKey.all.first,
    );
    final value = widget.state.adjustValue(_key);
    return _PanelShell(
      title: entry.label,
      onReset: widget.onReset,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LabeledSlider(
            label: entry.label,
            value: value,
            min: -1,
            max: 1,
            onChanged: (v) => widget.onChanged(_key, v),
            valueLabel: (value * 100).toStringAsFixed(0),
          ),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: MinisImageEditAdjustKey.all.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final e = MinisImageEditAdjustKey.all[i];
                final sel = e.key == _key;
                final v = widget.state.adjustValue(e.key);
                final dot = v.abs() > 0.001;
                return GestureDetector(
                  onTap: () => setState(() => _key = e.key),
                  child: SizedBox(
                    width: 64,
                    child: Column(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: sel
                                ? MinisImageEditTheme.accent.withValues(alpha: 0.15)
                                : MinisImageEditTheme.surface2,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: sel
                                  ? MinisImageEditTheme.accent
                                  : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                e.icon,
                                color: sel
                                    ? MinisImageEditTheme.accent
                                    : Colors.white,
                                size: 22,
                              ),
                              if (dot)
                                Positioned(
                                  right: 4,
                                  top: 4,
                                  child: Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      color: MinisImageEditTheme.accent,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          e.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: sel
                                ? MinisImageEditTheme.accent
                                : MinisImageEditTheme.textSecondary,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// ------------- FILTERS -------------
class MinisImageEditFilterPanel extends StatelessWidget {
  const MinisImageEditFilterPanel({
    super.key,
    required this.state,
    required this.sourceFile,
    required this.onPick,
    required this.onIntensity,
    required this.onReset,
  });

  final MinisImageEditEditorState state;
  final File? sourceFile;
  final ValueChanged<MinisImageEditFilter> onPick;
  final ValueChanged<double> onIntensity;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    const filters = MinisImageEditFilter.values;
    return _PanelShell(
      title: 'Filters',
      onReset: onReset,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.filter != MinisImageEditFilter.none)
            _LabeledSlider(
              label: 'Intensity',
              value: state.filterIntensity,
              min: 0,
              max: 1,
              onChanged: onIntensity,
              valueLabel: (state.filterIntensity * 100).toStringAsFixed(0),
            ),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final f = filters[i];
                final sel = state.filter == f;
                return GestureDetector(
                  onTap: () => onPick(f),
                  child: SizedBox(
                    width: 72,
                    child: Column(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: sel
                                  ? MinisImageEditTheme.accent
                                  : Colors.transparent,
                              width: 2,
                            ),
                            color: MinisImageEditTheme.surface2,
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: _FilterThumb(
                            file: sourceFile,
                            filter: f,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          f.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: sel
                                ? MinisImageEditTheme.accent
                                : MinisImageEditTheme.textSecondary,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterThumb extends StatelessWidget {
  const _FilterThumb({required this.file, required this.filter});
  final File? file;
  final MinisImageEditFilter filter;
  @override
  Widget build(BuildContext context) {
    final f = file;
    final cf = ColorFilter.matrix(
      MinisImageEditColorMatrix.preset(filter, 1.0),
    );
    if (f == null || !f.existsSync()) {
      return ColorFiltered(
        colorFilter: cf,
        child: Container(
          color: MinisImageEditTheme.surface,
          alignment: Alignment.center,
          child: const Icon(Icons.image_outlined,
              color: Colors.white24, size: 24),
        ),
      );
    }
    return ColorFiltered(
      colorFilter: cf,
      child: Image.file(
        f,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: 128,
        errorBuilder: (_, __, ___) =>
            const ColoredBox(color: MinisImageEditTheme.surface),
      ),
    );
  }
}

/// ------------- DECORATE (text + sticker + emoji + draw) -------------
class MinisImageEditDecoratePanel extends StatelessWidget {
  const MinisImageEditDecoratePanel({
    super.key,
    required this.state,
    required this.viewId,
    required this.onAddText,
    required this.onOpenEmoji,
    required this.onPickSticker,
    required this.onChangeTool,
  });

  final MinisImageEditEditorState state;
  final int? viewId;
  final VoidCallback onAddText;
  final VoidCallback onOpenEmoji;
  final VoidCallback onPickSticker;
  final ValueChanged<MinisImageEditDecorateTool> onChangeTool;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: MinisImageEditTheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DecorateTabs(state: state, onChange: onChangeTool),
          const Divider(height: 1, color: MinisImageEditTheme.divider),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            child: switch (state.decorateTool) {
              MinisImageEditDecorateTool.text => _DecorateActions(
                  actions: [
                    _DecorateAction(
                      icon: Icons.text_fields,
                      label: 'Add text',
                      onTap: onAddText,
                    ),
                  ],
                ),
              MinisImageEditDecorateTool.sticker => _DecorateActions(
                  actions: [
                    _DecorateAction(
                      icon: Icons.emoji_symbols,
                      label: 'Sticker pack',
                      onTap: onPickSticker,
                    ),
                  ],
                ),
              MinisImageEditDecorateTool.emoji => _DecorateActions(
                  actions: [
                    _DecorateAction(
                      icon: Icons.emoji_emotions_outlined,
                      label: 'Open emoji',
                      onTap: onOpenEmoji,
                    ),
                  ],
                ),
              MinisImageEditDecorateTool.draw =>
                _DrawTools(state: state),
            },
          ),
        ],
      ),
    );
  }
}

class _DecorateTabs extends StatelessWidget {
  const _DecorateTabs({required this.state, required this.onChange});
  final MinisImageEditEditorState state;
  final ValueChanged<MinisImageEditDecorateTool> onChange;

  static const _entries = <(MinisImageEditDecorateTool, IconData, String)>[
    (MinisImageEditDecorateTool.text, Icons.text_fields, 'Text'),
    (MinisImageEditDecorateTool.sticker, Icons.emoji_symbols, 'Sticker'),
    (MinisImageEditDecorateTool.emoji, Icons.emoji_emotions_outlined, 'Emoji'),
    (MinisImageEditDecorateTool.draw, Icons.brush_outlined, 'Draw'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final e in _entries)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChange(e.$1),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      e.$2,
                      size: 20,
                      color: state.decorateTool == e.$1
                          ? MinisImageEditTheme.accent
                          : Colors.white70,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.$3,
                      style: TextStyle(
                        fontSize: 10,
                        color: state.decorateTool == e.$1
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

class _DecorateAction {
  const _DecorateAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _DecorateActions extends StatelessWidget {
  const _DecorateActions({required this.actions});
  final List<_DecorateAction> actions;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final a in actions)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: GestureDetector(
                onTap: a.onTap,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(
                        color: MinisImageEditTheme.surface2,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(a.icon, color: Colors.white, size: 28),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      a.label,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
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

class _DrawTools extends StatelessWidget {
  const _DrawTools({required this.state});
  final MinisImageEditEditorState state;
  static const _palette = <int>[
    0xFFFFFFFF,
    0xFF000000,
    0xFFFF5252,
    0xFFFFAB40,
    0xFFFFEB3B,
    0xFF69F0AE,
    0xFF00E5FF,
    0xFF40C4FF,
    0xFFE040FB,
    0xFFFF80AB,
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                'Size',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: state.brushSize,
                  min: 2,
                  max: 80,
                  activeColor: MinisImageEditTheme.accent,
                  onChanged: (v) => state.brushSize = v,
                ),
              ),
              Text(
                state.brushSize.toStringAsFixed(0),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              const Text(
                'Hardness',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: state.brushHardness,
                  min: 0,
                  max: 1,
                  activeColor: MinisImageEditTheme.accent,
                  onChanged: (v) => state.brushHardness = v,
                ),
              ),
              Text(
                (state.brushHardness * 100).toStringAsFixed(0),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              GestureDetector(
                onTap: () => state.brushEraser = !state.brushEraser,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: state.brushEraser
                        ? MinisImageEditTheme.accent.withValues(alpha: 0.2)
                        : MinisImageEditTheme.surface2,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: state.brushEraser
                          ? MinisImageEditTheme.accent
                          : Colors.transparent,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        state.brushEraser ? Icons.cleaning_services : Icons.brush,
                        size: 16,
                        color: state.brushEraser
                            ? MinisImageEditTheme.accent
                            : Colors.white70,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        state.brushEraser ? 'Eraser' : 'Brush',
                        style: TextStyle(
                          color: state.brushEraser
                              ? MinisImageEditTheme.accent
                              : Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _palette.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final c = _palette[i];
                      final sel = state.brushColor == c && !state.brushEraser;
                      return GestureDetector(
                        onTap: () {
                          state.brushColor = c;
                          state.brushEraser = false;
                        },
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: sel
                                  ? MinisImageEditTheme.accent
                                  : Colors.white24,
                              width: sel ? 2 : 1,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ------------- RETOUCH -------------
class MinisImageEditRetouchPanel extends StatelessWidget {
  const MinisImageEditRetouchPanel({
    super.key,
    required this.state,
    required this.onChangeTool,
    required this.onBeautifyChanged,
    required this.onRemoveBg,
    required this.onLiquifyPreset,
  });

  final MinisImageEditEditorState state;
  final ValueChanged<MinisImageEditRetouchTool> onChangeTool;
  final void Function(String key, double value) onBeautifyChanged;
  final VoidCallback onRemoveBg;
  final ValueChanged<String> onLiquifyPreset;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: MinisImageEditTheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RetouchTabs(state: state, onChange: onChangeTool),
          const Divider(height: 1, color: MinisImageEditTheme.divider),
          switch (state.retouchTool) {
            MinisImageEditRetouchTool.beautify => _BeautifyBody(
                state: state,
                onChanged: onBeautifyChanged,
              ),
            MinisImageEditRetouchTool.heal => _HealBody(state: state),
            MinisImageEditRetouchTool.liquify => _LiquifyBody(
                onPreset: onLiquifyPreset,
              ),
            MinisImageEditRetouchTool.removeBg => _RemoveBgBody(
                state: state,
                onRemoveBg: onRemoveBg,
              ),
          },
        ],
      ),
    );
  }
}

class _RetouchTabs extends StatelessWidget {
  const _RetouchTabs({required this.state, required this.onChange});
  final MinisImageEditEditorState state;
  final ValueChanged<MinisImageEditRetouchTool> onChange;

  static const _entries = <(MinisImageEditRetouchTool, IconData, String)>[
    (MinisImageEditRetouchTool.beautify, Icons.face_retouching_natural, 'Beautify'),
    (MinisImageEditRetouchTool.heal, Icons.healing, 'Heal'),
    (MinisImageEditRetouchTool.liquify, Icons.waves, 'Liquify'),
    (MinisImageEditRetouchTool.removeBg, Icons.layers_clear, 'BG'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final e in _entries)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChange(e.$1),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      e.$2,
                      size: 20,
                      color: state.retouchTool == e.$1
                          ? MinisImageEditTheme.accent
                          : Colors.white70,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.$3,
                      style: TextStyle(
                        fontSize: 10,
                        color: state.retouchTool == e.$1
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

class _BeautifyBody extends StatelessWidget {
  const _BeautifyBody({required this.state, required this.onChanged});
  final MinisImageEditEditorState state;
  final void Function(String key, double value) onChanged;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LabeledSlider(
            label: 'Skin smooth',
            value: state.beautifySkin,
            min: 0,
            max: 1,
            onChanged: (v) => onChanged('skin', v),
            valueLabel: (state.beautifySkin * 100).toStringAsFixed(0),
          ),
          _LabeledSlider(
            label: 'Teeth white',
            value: state.beautifyTeeth,
            min: 0,
            max: 1,
            onChanged: (v) => onChanged('teeth', v),
            valueLabel: (state.beautifyTeeth * 100).toStringAsFixed(0),
          ),
          _LabeledSlider(
            label: 'Eye bright',
            value: state.beautifyEyes,
            min: 0,
            max: 1,
            onChanged: (v) => onChanged('eyes', v),
            valueLabel: (state.beautifyEyes * 100).toStringAsFixed(0),
          ),
        ],
      ),
    );
  }
}

class _HealBody extends StatelessWidget {
  const _HealBody({required this.state});
  final MinisImageEditEditorState state;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Tap a spot on the photo to remove it.',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 8),
          _LabeledSlider(
            label: 'Radius',
            value: state.healRadius,
            min: 4,
            max: 96,
            onChanged: (v) => state.healRadius = v,
            valueLabel: state.healRadius.toStringAsFixed(0),
          ),
        ],
      ),
    );
  }
}

class _LiquifyBody extends StatelessWidget {
  const _LiquifyBody({required this.onPreset});
  final ValueChanged<String> onPreset;
  static const _presets = <(String, IconData, String)>[
    ('slim', Icons.compress, 'Slim'),
    ('eyes', Icons.remove_red_eye_outlined, 'Eyes'),
    ('chin', Icons.face_2_outlined, 'Chin'),
    ('nose', Icons.face_outlined, 'Nose'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 110,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final p in _presets)
            GestureDetector(
              onTap: () => onPreset(p.$1),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: MinisImageEditTheme.surface2,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(p.$2, color: Colors.white, size: 24),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    p.$3,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RemoveBgBody extends StatelessWidget {
  const _RemoveBgBody({required this.state, required this.onRemoveBg});
  final MinisImageEditEditorState state;
  final VoidCallback onRemoveBg;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 110,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: state.removedBg
                    ? MinisImageEditTheme.accent.withValues(alpha: 0.2)
                    : MinisImageEditTheme.surface2,
                shape: BoxShape.circle,
                border: Border.all(
                  color: state.removedBg
                      ? MinisImageEditTheme.accent
                      : Colors.transparent,
                ),
              ),
              child: IconButton(
                icon: Icon(
                  Icons.layers_clear,
                  color: state.removedBg
                      ? MinisImageEditTheme.accent
                      : Colors.white,
                ),
                onPressed: onRemoveBg,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              state.removedBg
                  ? 'Background removed'
                  : 'Remove background',
              style: TextStyle(
                color: state.removedBg
                    ? MinisImageEditTheme.accent
                    : Colors.white70,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ------------- TEXT EDITOR SHEET -------------
class MinisImageEditTextSheet extends StatefulWidget {
  const MinisImageEditTextSheet({
    super.key,
    required this.channel,
    required this.fonts,
    this.initial,
  });

  final MinisImageEditChannel channel;
  final List<String> fonts;
  final MinisImageEditOverlay? initial;

  @override
  State<MinisImageEditTextSheet> createState() =>
      _MinisImageEditTextSheetState();
}

class _MinisImageEditTextSheetState extends State<MinisImageEditTextSheet> {
  late final TextEditingController _ctrl;
  late String _font;
  double _size = 32;
  int _color = 0xFFFFFFFF;
  int _bg = 0x00000000;
  String _align = 'center';

  static const _palette = <int>[
    0xFFFFFFFF,
    0xFF000000,
    0xFFFF5252,
    0xFFFFAB40,
    0xFFFFEB3B,
    0xFF69F0AE,
    0xFF00E5FF,
    0xFF40C4FF,
    0xFFE040FB,
    0xFFFF80AB,
  ];

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _ctrl = TextEditingController(text: init?.text ?? '');
    _font = init?.fontFamily ??
        (widget.fonts.isNotEmpty ? widget.fonts.first : 'System');
    _size = init?.fontSize ?? 32;
    _color = init?.color ?? 0xFFFFFFFF;
    _bg = init?.background ?? 0x00000000;
    _align = init?.align ?? 'center';
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  TextAlign get _tAlign {
    switch (_align) {
      case 'left':
        return TextAlign.left;
      case 'right':
        return TextAlign.right;
      default:
        return TextAlign.center;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        color: MinisImageEditTheme.surface,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Expanded(
                  child: Text(
                    'Text',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.check,
                      color: MinisImageEditTheme.accent),
                  onPressed: () {
                    final v = _ctrl.text.trim();
                    if (v.isEmpty) {
                      Navigator.of(context).pop();
                      return;
                    }
                    Navigator.of(context).pop(
                      MinisImageEditTextResult(
                        text: v,
                        font: _font,
                        size: _size,
                        color: _color,
                        background: _bg,
                        align: _align,
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Color(_bg).withValues(alpha: ((_bg >> 24) & 0xFF) / 255),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _ctrl,
                maxLines: 4,
                minLines: 1,
                textAlign: _tAlign,
                autofocus: true,
                style: TextStyle(
                  color: Color(_color),
                  fontSize: _size,
                  fontFamily: _font == 'System' ? null : _font,
                ),
                decoration: const InputDecoration(
                  hintText: 'Type something...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: Colors.white24),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.format_align_left,
                    color: _align == 'left'
                        ? MinisImageEditTheme.accent
                        : Colors.white70,
                  ),
                  onPressed: () => setState(() => _align = 'left'),
                ),
                IconButton(
                  icon: Icon(
                    Icons.format_align_center,
                    color: _align == 'center'
                        ? MinisImageEditTheme.accent
                        : Colors.white70,
                  ),
                  onPressed: () => setState(() => _align = 'center'),
                ),
                IconButton(
                  icon: Icon(
                    Icons.format_align_right,
                    color: _align == 'right'
                        ? MinisImageEditTheme.accent
                        : Colors.white70,
                  ),
                  onPressed: () => setState(() => _align = 'right'),
                ),
                IconButton(
                  icon: Icon(
                    Icons.format_color_fill,
                    color: ((_bg >> 24) & 0xFF) > 0
                        ? MinisImageEditTheme.accent
                        : Colors.white70,
                  ),
                  onPressed: () => setState(
                    () => _bg = ((_bg >> 24) & 0xFF) > 0 ? 0x00000000 : 0x80000000,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _size,
                    min: 12,
                    max: 96,
                    activeColor: MinisImageEditTheme.accent,
                    onChanged: (v) => setState(() => _size = v),
                  ),
                ),
              ],
            ),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _palette.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final c = _palette[i];
                  final sel = _color == c;
                  return GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: sel
                              ? MinisImageEditTheme.accent
                              : Colors.white24,
                          width: sel ? 2 : 1,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (widget.fonts.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.fonts.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final f = widget.fonts[i];
                    final sel = _font == f;
                    return GestureDetector(
                      onTap: () => setState(() => _font = f),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel
                              ? MinisImageEditTheme.accent.withValues(alpha: 0.15)
                              : MinisImageEditTheme.surface2,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: sel
                                ? MinisImageEditTheme.accent
                                : Colors.transparent,
                          ),
                        ),
                        child: Text(
                          f,
                          style: TextStyle(
                            fontFamily: f == 'System' ? null : f,
                            color: sel
                                ? MinisImageEditTheme.accent
                                : Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MinisImageEditTextResult {
  const MinisImageEditTextResult({
    required this.text,
    required this.font,
    required this.size,
    required this.color,
    required this.background,
    required this.align,
  });
  final String text;
  final String font;
  final double size;
  final int color;
  final int background;
  final String align;
}

/// ------------- STICKER PACK SHEET -------------
class MinisImageEditStickerSheet extends StatefulWidget {
  const MinisImageEditStickerSheet({super.key, required this.channel});
  final MinisImageEditChannel channel;
  @override
  State<MinisImageEditStickerSheet> createState() =>
      _MinisImageEditStickerSheetState();
}

class _MinisImageEditStickerSheetState
    extends State<MinisImageEditStickerSheet> {
  Future<List<MinisImageStickerPack>>? _future;
  int _packIndex = 0;

  @override
  void initState() {
    super.initState();
    _future = widget.channel.listStickerPacks();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: MinisImageEditTheme.surface,
      height: MediaQuery.of(context).size.height * 0.55,
      child: FutureBuilder<List<MinisImageStickerPack>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(
                color: MinisImageEditTheme.accent,
              ),
            );
          }
          final packs = snap.data ?? const <MinisImageStickerPack>[];
          if (packs.isEmpty) {
            return const Center(
              child: Text(
                'No sticker packs',
                style: TextStyle(color: Colors.white70),
              ),
            );
          }
          final idx = _packIndex.clamp(0, packs.length - 1);
          final pack = packs[idx];
          return Column(
            children: [
              SizedBox(
                height: 48,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: packs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final p = packs[i];
                    final sel = i == idx;
                    return GestureDetector(
                      onTap: () => setState(() => _packIndex = i),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: sel
                              ? MinisImageEditTheme.accent.withValues(alpha: 0.15)
                              : MinisImageEditTheme.surface2,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          p.label,
                          style: TextStyle(
                            color: sel
                                ? MinisImageEditTheme.accent
                                : Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Divider(height: 1, color: MinisImageEditTheme.divider),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: pack.stickers.length,
                  itemBuilder: (_, i) {
                    final asset = pack.stickers[i];
                    return GestureDetector(
                      onTap: () => Navigator.of(context).pop(asset),
                      child: Container(
                        decoration: BoxDecoration(
                          color: MinisImageEditTheme.surface2,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _StickerThumb(assetId: asset),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StickerThumb extends StatelessWidget {
  const _StickerThumb({required this.assetId});
  final String assetId;
  @override
  Widget build(BuildContext context) {
    // Sticker assetIds may be paths or asset keys. Try file first, fall
    // back to a placeholder so the grid stays usable while the native
    // catalog wires real artwork.
    final file = File(assetId);
    if (file.existsSync()) {
      return Image.file(file, fit: BoxFit.cover);
    }
    return const Center(
      child: Icon(Icons.image_outlined, color: Colors.white24, size: 28),
    );
  }
}

/// ------------- SHARED PANEL CHROME -------------
class _PanelShell extends StatelessWidget {
  const _PanelShell({
    required this.title,
    required this.child,
    this.onReset,
    this.onApply,
  });
  final String title;
  final Widget child;
  final VoidCallback? onReset;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: MinisImageEditTheme.surface,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                if (onReset != null)
                  TextButton(
                    onPressed: onReset,
                    style: TextButton.styleFrom(
                      foregroundColor: MinisImageEditTheme.textSecondary,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Reset', style: TextStyle(fontSize: 12)),
                  ),
                if (onApply != null) ...[
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: onApply,
                    style: TextButton.styleFrom(
                      foregroundColor: MinisImageEditTheme.accent,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Apply', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected
              ? MinisImageEditTheme.accent.withValues(alpha: 0.15)
              : MinisImageEditTheme.surface2,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? MinisImageEditTheme.accent
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? MinisImageEditTheme.accent : Colors.white,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: selected
                  ? MinisImageEditTheme.accent.withValues(alpha: 0.15)
                  : MinisImageEditTheme.surface2,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: selected ? MinisImageEditTheme.accent : Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: selected
                  ? MinisImageEditTheme.accent
                  : MinisImageEditTheme.textSecondary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.valueLabel,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String? valueLabel;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: MinisImageEditTheme.accent,
                inactiveTrackColor: MinisImageEditTheme.surface2,
                thumbColor: MinisImageEditTheme.accent,
                overlayColor:
                    MinisImageEditTheme.accent.withValues(alpha: 0.2),
                trackHeight: 2,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              valueLabel ?? value.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// ------------- EXPORT OPTIONS SHEET -------------
class MinisImageEditExportOptions {
  const MinisImageEditExportOptions({
    required this.format,
    required this.quality,
    this.maxDim,
  });
  final MinisImageExportFormat format;
  final int quality;
  final int? maxDim;
}

class MinisImageEditExportSheet extends StatefulWidget {
  const MinisImageEditExportSheet({super.key, required this.initial});
  final MinisImageEditExportOptions initial;
  @override
  State<MinisImageEditExportSheet> createState() =>
      _MinisImageEditExportSheetState();
}

class _MinisImageEditExportSheetState extends State<MinisImageEditExportSheet> {
  late MinisImageExportFormat _format;
  late int _quality;
  int? _maxDim;

  static const _dimOptions = <int?>[null, 720, 1080, 1440, 2160, 4320];

  @override
  void initState() {
    super.initState();
    _format = widget.initial.format;
    _quality = widget.initial.quality;
    _maxDim = widget.initial.maxDim;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: MinisImageEditTheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const Expanded(
                child: Text(
                  'Export options',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: MinisImageEditTheme.accent,
                ),
                onPressed: () => Navigator.of(context).pop(
                  MinisImageEditExportOptions(
                    format: _format,
                    quality: _quality,
                    maxDim: _maxDim,
                  ),
                ),
                child: const Text('Save'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Format',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final f in MinisImageExportFormat.values)
                _Chip(
                  label: f.fileExtension.toUpperCase(),
                  selected: _format == f,
                  onTap: () => setState(() => _format = f),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text(
                'Quality',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: _quality.toDouble(),
                  min: 50,
                  max: 100,
                  divisions: 50,
                  activeColor: MinisImageEditTheme.accent,
                  onChanged: (v) => setState(() => _quality = v.round()),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '$_quality',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Max dimension',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final d in _dimOptions)
                _Chip(
                  label: d == null ? 'Original' : '${d}p',
                  selected: _maxDim == d,
                  onTap: () => setState(() => _maxDim = d),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ------------- LAYERS SHEET -------------
class MinisImageEditLayersSheet extends StatelessWidget {
  const MinisImageEditLayersSheet({
    super.key,
    required this.state,
    required this.onDelete,
    required this.onSelect,
  });

  final MinisImageEditEditorState state;
  final ValueChanged<int> onDelete;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final overlays = state.overlays;
    return Container(
      color: MinisImageEditTheme.surface,
      height: MediaQuery.of(context).size.height * 0.45,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: MinisImageEditTheme.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Layers',
            style: TextStyle(color: Colors.white, fontSize: 14),
          ),
          const Divider(color: MinisImageEditTheme.divider, height: 16),
          Expanded(
            child: overlays.isEmpty
                ? const Center(
                    child: Text(
                      'No overlays yet',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.separated(
                    itemCount: overlays.length,
                    separatorBuilder: (_, __) => const Divider(
                      color: MinisImageEditTheme.divider,
                      height: 1,
                    ),
                    itemBuilder: (_, i) {
                      final o = overlays[overlays.length - 1 - i];
                      return ListTile(
                        leading: Icon(
                          _kindIcon(o),
                          color: state.selectedOverlay == o.id
                              ? MinisImageEditTheme.accent
                              : Colors.white70,
                        ),
                        title: Text(
                          _kindLabel(o),
                          style: TextStyle(
                            color: state.selectedOverlay == o.id
                                ? MinisImageEditTheme.accent
                                : Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: o.text != null
                            ? Text(
                                o.text!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              )
                            : null,
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: MinisImageEditTheme.danger,
                          ),
                          onPressed: () => onDelete(o.id),
                        ),
                        onTap: () {
                          onSelect(o.id);
                          Navigator.of(context).pop();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  IconData _kindIcon(MinisImageEditOverlay o) {
    switch (o.kind.wireName) {
      case 'text':
        return Icons.text_fields;
      case 'sticker':
        return Icons.emoji_symbols;
      case 'emoji':
        return Icons.emoji_emotions_outlined;
      default:
        return Icons.layers_outlined;
    }
  }

  String _kindLabel(MinisImageEditOverlay o) {
    switch (o.kind.wireName) {
      case 'text':
        return 'Text';
      case 'sticker':
        return 'Sticker';
      case 'emoji':
        return 'Emoji';
      default:
        return 'Layer';
    }
  }
}

/// Helper: open the emoji bottom sheet, returning the chosen code point.
Future<int?> showImageEditEmojiSheet(BuildContext context) {
  final completer = Completer<int?>();
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: MinisImageEditTheme.bg,
    isScrollControlled: true,
    builder: (_) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.55,
      child: MinisEmojiPicker(
        onSelected: (cp) {
          if (!completer.isCompleted) completer.complete(cp);
          Navigator.of(context).pop();
        },
      ),
    ),
  ).whenComplete(() {
    if (!completer.isCompleted) completer.complete(null);
  });
  return completer.future;
}
