import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:loopit_minis/loopit_minis.dart';

import 'editor_config.dart';
import 'editor_giphy.dart';
import 'editor_state.dart';

// ─── Simple sheets ────────────────────────────────────────────────

Future<double?> showSpeedSheet(BuildContext context, double current) {
  const options = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0];
  return showModalBottomSheet<double>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Speed',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final v in options)
                  ChoiceChip(
                    label: Text('$v×'),
                    selected: v == current,
                    onSelected: (_) => Navigator.pop(context, v),
                    selectedColor: kAccentCyan,
                    backgroundColor: kBgSurface2,
                    labelStyle: TextStyle(
                      color: v == current ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Future<double?> showVolumeSheet(BuildContext context, double current) {
  double v = current;
  return showModalBottomSheet<double>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Volume',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  Text('${(v * 100).round()}%',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()])),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              Slider(
                value: v,
                min: 0,
                max: 1.5,
                divisions: 15,
                activeColor: kAccentCyan,
                onChanged: (nv) => set(() => v = nv),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, v),
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccentCyan,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: const Text('Apply',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<String?> showTextEntrySheet(BuildContext context,
    {required String title, String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 16)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                cursorColor: kAccentCyan,
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: kBgSurface2,
                  hintText: 'Type here…',
                  hintStyle: TextStyle(color: kTextSecondary),
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, ctrl.text),
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccentCyan,
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─── Text editor with style ──────────────────────────────────────

class TextEditorResult {
  final String text;
  final Color color;
  final Color? bgColor;
  final double fontSize;
  final bool bold;
  final bool italic;
  final TextAlign align;
  TextEditorResult({
    required this.text,
    required this.color,
    required this.bgColor,
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.align,
  });
}

Future<TextEditorResult?> showTextEditorSheet(BuildContext context,
    {String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  Color color = Colors.white;
  Color? bg;
  double size = 36;
  bool bold = false;
  bool italic = false;
  TextAlign align = TextAlign.center;

  const colors = [
    Colors.white,
    Colors.black,
    Color(0xFFFFEB3B),
    Color(0xFFFF5252),
    Color(0xFF00E5FF),
    Color(0xFF69F0AE),
    Color(0xFFE040FB),
    Color(0xFFFF9800),
  ];

  return showModalBottomSheet<TextEditorResult>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('Text',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 16)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.format_bold, color: Colors.white),
                      onPressed: () => set(() => bold = !bold),
                      color: bold ? kAccentCyan : Colors.white,
                    ),
                    IconButton(
                      icon:
                          const Icon(Icons.format_italic, color: Colors.white),
                      onPressed: () => set(() => italic = !italic),
                      color: italic ? kAccentCyan : Colors.white,
                    ),
                    IconButton(
                      icon: Icon(
                        align == TextAlign.left
                            ? Icons.format_align_left
                            : align == TextAlign.right
                                ? Icons.format_align_right
                                : Icons.format_align_center,
                        color: Colors.white,
                      ),
                      onPressed: () => set(() {
                        align = align == TextAlign.left
                            ? TextAlign.center
                            : align == TextAlign.center
                                ? TextAlign.right
                                : TextAlign.left;
                      }),
                    ),
                  ],
                ),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: TextStyle(
                    color: color,
                    fontSize: size,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                  ),
                  textAlign: align,
                  cursorColor: kAccentCyan,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: bg ?? kBgSurface2,
                    border:
                        const OutlineInputBorder(borderSide: BorderSide.none),
                  ),
                  maxLines: 4,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.format_size,
                        color: Colors.white, size: 16),
                    Expanded(
                      child: Slider(
                        value: size,
                        min: 14,
                        max: 80,
                        activeColor: kAccentCyan,
                        onChanged: (v) => set(() => size = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text('Color',
                    style: TextStyle(color: kTextSecondary, fontSize: 11)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: colors.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final c = colors[i];
                      return GestureDetector(
                        onTap: () => set(() => color = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color == c ? kAccentCyan : Colors.white24,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 6),
                const Text('Background',
                    style: TextStyle(color: kTextSecondary, fontSize: 11)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: colors.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      if (i == 0) {
                        return GestureDetector(
                          onTap: () => set(() => bg = null),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: bg == null ? kAccentCyan : Colors.white24,
                                width: 2,
                              ),
                            ),
                            child: const Icon(Icons.block,
                                color: Colors.white, size: 14),
                          ),
                        );
                      }
                      final c = colors[i - 1];
                      return GestureDetector(
                        onTap: () => set(() => bg = c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: bg == c ? kAccentCyan : Colors.white24,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel',
                          style: TextStyle(color: Colors.white70)),
                    ),
                    FilledButton(
                      onPressed: () {
                        if (ctrl.text.trim().isEmpty) return;
                        Navigator.pop(
                          ctx,
                          TextEditorResult(
                            text: ctrl.text,
                            color: color,
                            bgColor: bg,
                            fontSize: size,
                            bold: bold,
                            italic: italic,
                            align: align,
                          ),
                        );
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: kAccentCyan,
                        foregroundColor: Colors.black,
                      ),
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// ─── Draw sheet ───────────────────────────────────────────────────

Future<DrawStroke?> showDrawSheet(BuildContext context) {
  final points = <Offset>[];
  Color color = Colors.white;
  double width = 4;

  const palette = [
    Colors.white,
    Colors.black,
    Color(0xFFFFEB3B),
    Color(0xFFFF5252),
    Color(0xFF00E5FF),
    Color(0xFF69F0AE),
  ];

  return showModalBottomSheet<DrawStroke>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text('Draw',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Colors.white),
                    onPressed: () => set(() => points.clear()),
                  ),
                ],
              ),
              Container(
                height: 240,
                color: Colors.black,
                child: LayoutBuilder(
                  builder: (_, c) => GestureDetector(
                    onPanUpdate: (d) {
                      set(() => points.add(Offset(
                            d.localPosition.dx / c.maxWidth,
                            d.localPosition.dy / c.maxHeight,
                          )));
                    },
                    child: CustomPaint(
                      painter: _LivePainter(points, color, width),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.line_weight, color: Colors.white, size: 16),
                  Expanded(
                    child: Slider(
                      value: width,
                      min: 1,
                      max: 20,
                      activeColor: kAccentCyan,
                      onChanged: (v) => set(() => width = v),
                    ),
                  ),
                ],
              ),
              SizedBox(
                height: 32,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: palette.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final c = palette[i];
                    return GestureDetector(
                      onTap: () => set(() => color = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == c ? kAccentCyan : Colors.white24,
                            width: 2,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (points.length < 2) return;
                      Navigator.pop(
                          ctx,
                          DrawStroke(
                            points: List.of(points),
                            color: color,
                            width: width,
                          ));
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccentCyan,
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.points, this.color, this.width);
  final List<Offset> points;
  final Color color;
  final double width;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(points.first.dx * size.width, points.first.dy * size.height);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx * size.width, points[i].dy * size.height);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LivePainter old) =>
      old.points.length != points.length ||
      old.color != color ||
      old.width != width;
}

// ─── Voiceover ────────────────────────────────────────────────────

Future<String?> showVoiceoverSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: kBgSurface,
    isDismissible: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _VoiceoverPanel(),
  );
}

class _VoiceoverPanel extends StatefulWidget {
  const _VoiceoverPanel();
  @override
  State<_VoiceoverPanel> createState() => _VoiceoverPanelState();
}

class _VoiceoverPanelState extends State<_VoiceoverPanel> {
  final _rec = MinisAudioRecorder();
  bool _recording = false;
  String? _path;
  int _seconds = 0;
  Timer? _timer;

  Future<void> _start() async {
    final dir = await NativePaths.cacheDir() ?? Directory.systemTemp.path;
    final path =
        '$dir/voiceover_${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      await _rec.start(
        path: path,
        format: MinisAudioFormat.aac,
      );
      setState(() {
        _recording = true;
        _path = path;
        _seconds = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() => _seconds++);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Record failed: $e')),
      );
    }
  }

  Future<void> _stop() async {
    _timer?.cancel();
    try {
      await _rec.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _recording = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_recording) {
      _rec.stop().then((_) {}, onError: (_) {});
    }
    super.dispose();
  }

  String _fmt(int s) {
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: 48),
                const Expanded(
                  child: Text('Voiceover',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _recording ? null : () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_fmt(_seconds),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontFeatures: [FontFeature.tabularFigures()])),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _recording ? _stop : _start,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _recording ? Colors.red : kAccentCyan,
                ),
                child: Icon(
                  _recording ? Icons.stop : Icons.mic,
                  color: Colors.black,
                  size: 36,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.white70)),
                ),
                FilledButton(
                  onPressed: _path != null && !_recording
                      ? () => Navigator.pop(context, _path)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccentCyan,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Simple picker ────────────────────────────────────────────────

Future<String?> showSimplePickerSheet(
  BuildContext context, {
  required String title,
  required List<String> options,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final o in options)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(o, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context, o),
              ),
          ],
        ),
      ),
    ),
  );
}

Future<String?> showOverlayPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text('Add overlay',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _BigChoice(
                  icon: Icons.text_fields,
                  label: 'Text',
                  onTap: () => Navigator.pop(context, 'text'),
                ),
                _BigChoice(
                  icon: Icons.emoji_emotions,
                  label: 'Sticker',
                  onTap: () => Navigator.pop(context, 'sticker'),
                ),
                _BigChoice(
                  icon: Icons.image,
                  label: 'Picture',
                  onTap: () => Navigator.pop(context, 'picture'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

class _BigChoice extends StatelessWidget {
  const _BigChoice(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: kBgSurface2,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}

// ─── Auto captions sheet ──────────────────────────────────────────

class AutoCaptionSettings {
  final String generateFrom;
  final String language;
  AutoCaptionSettings(this.generateFrom, this.language);
}

Future<AutoCaptionSettings?> showAutoCaptionsSheet(BuildContext context) {
  String generateFrom = 'Video';
  String language = 'Auto detect';
  return showModalBottomSheet<AutoCaptionSettings>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Spacer(),
                  const Text('Auto captions',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _SettingRow(
                icon: Icons.video_camera_back,
                label: 'Generate from',
                value: generateFrom,
                onTap: () async {
                  final v = await showSimplePickerSheet(ctx,
                      title: 'Generate from',
                      options: ['Video', 'Recorded audio']);
                  if (v != null) set(() => generateFrom = v);
                },
              ),
              const SizedBox(height: 8),
              _SettingRow(
                icon: Icons.translate,
                label: 'Spoken language',
                value: language,
                onTap: () async {
                  final v = await showSimplePickerSheet(ctx,
                      title: 'Spoken language',
                      options: [
                        'Auto detect',
                        'English',
                        'Spanish',
                        'French',
                        'Hindi',
                        'Mandarin'
                      ]);
                  if (v != null) set(() => language = v);
                },
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: kBgSurface2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.closed_caption,
                            color: Colors.white, size: 16),
                        SizedBox(width: 6),
                        Text('Templates',
                            style: TextStyle(color: Colors.white)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 72,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10),
                        itemCount: _kCaptionTemplates.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final selected = i == 0;
                          return Container(
                            width: 84,
                            height: 60,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: kBgSurface,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: selected
                                    ? kAccentCyan
                                    : Colors.white24,
                                width: selected ? 2 : 1,
                              ),
                            ),
                            child: Text(
                              _kCaptionTemplates[i],
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: kBgSurface2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFAA00FF), Color(0xFFFF40A0)],
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('Pro',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 8),
                    const Text('Advanced options',
                        style: TextStyle(color: Colors.white)),
                    const Spacer(),
                    const Icon(Icons.keyboard_arrow_down,
                        color: Colors.white),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                      ctx, AutoCaptionSettings(generateFrom, language)),
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccentCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: const Text('Generate',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: kBgSurface2,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(color: Colors.white)),
            const Spacer(),
            Text(value, style: const TextStyle(color: kTextSecondary)),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: kTextSecondary, size: 18),
          ],
        ),
      ),
    );
  }
}

// ─── Ratio sheet ──────────────────────────────────────────────────

Future<AspectMode?> showRatioSheet(BuildContext context, AspectMode current) {
  return showModalBottomSheet<AspectMode>(
    context: context,
    backgroundColor: kBgSurface,
    builder: (_) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Ratio',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 16)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.check, color: kAccentCyan),
                  onPressed: () => Navigator.pop(context, current),
                ),
              ],
            ),
            SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: AspectMode.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) {
                  final m = AspectMode.values[i];
                  final selected = m == current;
                  return GestureDetector(
                    onTap: () => Navigator.pop(context, m),
                    child: Container(
                      width: 64,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? Colors.white : Colors.white24,
                          width: selected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _ratioIcon(m),
                          const SizedBox(height: 4),
                          Text(m.label,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _ratioIcon(AspectMode m) {
  final ar = m.ratio == 0 ? 9 / 16 : m.ratio;
  return Container(
    width: 24,
    height: 24 / ar,
    decoration: BoxDecoration(
      border: Border.all(color: Colors.white, width: 1.5),
    ),
  );
}

// ─── Background sheet ────────────────────────────────────────────

Future<void> showBackgroundSheet(
  BuildContext context,
  EditorState st, {
  required VoidCallback onChanged,
  required VoidCallback onPushUndo,
}) async {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Background',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _BgChoice(
                    icon: Icons.color_lens,
                    label: 'Color',
                    selected: st.bgMode == BackgroundMode.color,
                    onTap: () {
                      onPushUndo();
                      st.bgMode = BackgroundMode.color;
                      onChanged();
                      set(() {});
                    },
                  ),
                  _BgChoice(
                    icon: Icons.landscape,
                    label: 'Image',
                    selected: st.bgMode == BackgroundMode.image,
                    onTap: () async {
                      final p = await NativePicker.pickImage();
                      if (p == null) return;
                      onPushUndo();
                      st.bgMode = BackgroundMode.image;
                      st.bgImagePath = p.path;
                      onChanged();
                      set(() {});
                    },
                  ),
                  _BgChoice(
                    icon: Icons.blur_on,
                    label: 'Blur',
                    selected: st.bgMode == BackgroundMode.blur,
                    onTap: () {
                      onPushUndo();
                      st.bgMode = BackgroundMode.blur;
                      onChanged();
                      set(() {});
                    },
                  ),
                  _BgChoice(
                    icon: Icons.block,
                    label: 'None',
                    selected: st.bgMode == BackgroundMode.none,
                    onTap: () {
                      onPushUndo();
                      st.bgMode = BackgroundMode.none;
                      onChanged();
                      set(() {});
                    },
                  ),
                ],
              ),
              if (st.bgMode == BackgroundMode.color) ...[
                const SizedBox(height: 16),
                const Text('Color',
                    style: TextStyle(color: kTextSecondary, fontSize: 11)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _bgColors.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final c = _bgColors[i];
                      final selected = st.bgColor == c;
                      return GestureDetector(
                        onTap: () {
                          onPushUndo();
                          st.bgColor = c;
                          onChanged();
                          set(() {});
                        },
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected ? kAccentCyan : Colors.white24,
                              width: 2,
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
      ),
    ),
  );
}

const _bgColors = [
  Colors.black,
  Colors.white,
  Color(0xFF263238),
  Color(0xFF3949AB),
  Color(0xFFD81B60),
  Color(0xFF43A047),
  Color(0xFFFB8C00),
  Color(0xFF6A1B9A),
];

class _BgChoice extends StatelessWidget {
  const _BgChoice({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: kBgSurface2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? kAccentCyan : Colors.transparent,
                width: 2,
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }
}

// ─── Filters / Adjust sheet ──────────────────────────────────────

Future<void> showFiltersAdjustSheet(
  BuildContext context,
  EditorState st, {
  required VoidCallback onChanged,
  required VoidCallback onPushUndo,
}) {
  int tab = 0;
  String adjustKey = 'brightness';
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _TabBtn('Filters', tab == 0, () => set(() => tab = 0)),
                  const SizedBox(width: 16),
                  _TabBtn('Adjust', tab == 1, () => set(() => tab = 1)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.check, color: kAccentCyan),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 12),
              if (tab == 0)
                _FiltersTab(state: st, onChanged: () {
                  onChanged();
                  set(() {});
                }, onPushUndo: onPushUndo),
              if (tab == 1)
                _AdjustTab(
                  state: st,
                  activeKey: adjustKey,
                  onChanged: () {
                    onChanged();
                    set(() {});
                  },
                  onSelect: (k) => set(() => adjustKey = k),
                  onPushUndo: onPushUndo,
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TabBtn extends StatelessWidget {
  const _TabBtn(this.label, this.active, this.onTap);
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  color: active ? Colors.white : kTextSecondary,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  fontSize: 14)),
          const SizedBox(height: 4),
          Container(
            height: 2,
            width: 32,
            color: active ? kAccentCyan : Colors.transparent,
          ),
        ],
      ),
    );
  }
}

class _FiltersTab extends StatelessWidget {
  const _FiltersTab({
    required this.state,
    required this.onChanged,
    required this.onPushUndo,
  });
  final EditorState state;
  final VoidCallback onChanged;
  final VoidCallback onPushUndo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 90,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: FilterPreset.values.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final p = FilterPreset.values[i];
              final selected = state.filter == p;
              return GestureDetector(
                onTap: () {
                  onPushUndo();
                  state.filter = p;
                  onChanged();
                },
                child: Column(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF4527A0), Color(0xFFE91E63)],
                        ),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? kAccentCyan : Colors.white24,
                          width: 2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(p.label,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10)),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Intensity',
                style: TextStyle(color: kTextSecondary, fontSize: 11)),
            Expanded(
              child: Slider(
                value: state.filterIntensity,
                activeColor: kAccentCyan,
                onChanged: (v) {
                  state.filterIntensity = v;
                  onChanged();
                },
              ),
            ),
            Text('${(state.filterIntensity * 100).round()}%',
                style: const TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

class _AdjustTab extends StatefulWidget {
  const _AdjustTab({
    required this.state,
    required this.activeKey,
    required this.onChanged,
    required this.onSelect,
    required this.onPushUndo,
  });
  final EditorState state;
  final String activeKey;
  final VoidCallback onChanged;
  final ValueChanged<String> onSelect;
  final VoidCallback onPushUndo;

  @override
  State<_AdjustTab> createState() => _AdjustTabState();
}

class _AdjustTabState extends State<_AdjustTab> {
  int _sub = 1;

  static const _tools = [
    ('brightness', Icons.wb_sunny, 'Brightness', null),
    ('contrast', Icons.contrast, 'Contrast', null),
    ('saturation', Icons.water_drop, 'Saturation', null),
    ('brilliance', Icons.flare, 'Brilliance', null),
    ('sharpen', Icons.change_history, 'Sharpen', null),
    ('clarity', Icons.details, 'Clarity', 'Free'),
    ('temperature', Icons.thermostat, 'Temp', null),
    ('tint', Icons.colorize, 'Tint', null),
    ('vibrance', Icons.invert_colors, 'Vibrance', null),
  ];

  double _getValue() {
    switch (widget.activeKey) {
      case 'brightness':
        return widget.state.adjust.brightness;
      case 'contrast':
        return widget.state.adjust.contrast;
      case 'saturation':
        return widget.state.adjust.saturation;
      case 'brilliance':
        return widget.state.adjust.brilliance;
      case 'sharpen':
        return widget.state.adjust.sharpen;
      case 'clarity':
        return widget.state.adjust.clarity;
      case 'temperature':
        return widget.state.adjust.temperature;
      case 'tint':
        return widget.state.adjust.tint;
      case 'vibrance':
        return widget.state.adjust.vibrance;
      default:
        return 0;
    }
  }

  void _setValue(double v) {
    switch (widget.activeKey) {
      case 'brightness':
        widget.state.adjust.brightness = v;
        break;
      case 'contrast':
        widget.state.adjust.contrast = v;
        break;
      case 'saturation':
        widget.state.adjust.saturation = v;
        break;
      case 'brilliance':
        widget.state.adjust.brilliance = v;
        break;
      case 'sharpen':
        widget.state.adjust.sharpen = v;
        break;
      case 'clarity':
        widget.state.adjust.clarity = v;
        break;
      case 'temperature':
        widget.state.adjust.temperature = v;
        break;
      case 'tint':
        widget.state.adjust.tint = v;
        break;
      case 'vibrance':
        widget.state.adjust.vibrance = v;
        break;
    }
  }

  void _applySmartPreset() {
    widget.onPushUndo();
    widget.state.adjust
      ..brightness = 0.10
      ..contrast = 0.20
      ..saturation = 0.15
      ..brilliance = 0.10
      ..sharpen = 0.20
      ..clarity = 0.15;
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SubTabBtn('Smart', _sub == 0, () {
              setState(() => _sub = 0);
              _applySmartPreset();
            }),
            const SizedBox(width: 14),
            _SubTabBtn('Customize', _sub == 1, () => setState(() => _sub = 1)),
          ],
        ),
        const SizedBox(height: 10),
        if (_sub == 0)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Smart adjustments applied. Switch to Customize to fine-tune.',
              style: TextStyle(color: kTextSecondary, fontSize: 12),
            ),
          )
        else ...[
          SizedBox(
            height: 80,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _tools.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) {
                final t = _tools[i];
                final selected = t.$1 == widget.activeKey;
                return GestureDetector(
                  onTap: () => widget.onSelect(t.$1),
                  child: Column(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color:
                                    selected ? kAccentCyan : Colors.white54,
                                width: 1.5,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Icon(t.$2,
                                color: selected ? kAccentCyan : Colors.white,
                                size: 22),
                          ),
                          if (t.$4 != null)
                            Positioned(
                              right: -6,
                              top: -2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: kAccentCyan,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  t.$4!,
                                  style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(t.$3,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10)),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Slider(
            value: _getValue(),
            min: -1.0,
            max: 1.0,
            activeColor: kAccentCyan,
            onChanged: (v) {
              _setValue(v);
              widget.onChanged();
            },
            onChangeStart: (_) => widget.onPushUndo(),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () {
              widget.onPushUndo();
              widget.state.adjust.reset();
              widget.onChanged();
            },
            child: const Row(
              children: [
                Icon(Icons.refresh, color: Colors.white, size: 16),
                SizedBox(width: 6),
                Text('Reset', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SubTabBtn extends StatelessWidget {
  const _SubTabBtn(this.label, this.active, this.onTap);
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
            color: active ? Colors.white : kTextSecondary,
            fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            fontSize: 13),
      ),
    );
  }
}

// ─── Sticker / GIPHY sheet ───────────────────────────────────────

Future<GiphyItem?> showStickerSheet(BuildContext context) {
  return showModalBottomSheet<GiphyItem>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _StickerPanel(),
  );
}

class _StickerPanel extends StatefulWidget {
  const _StickerPanel();
  @override
  State<_StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<_StickerPanel> {
  GiphyKind _kind = GiphyKind.stickers;
  final _query = TextEditingController();
  List<GiphyItem> _items = [];
  bool _loading = false;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = _query.text.trim().isEmpty
          ? await GiphyClient.instance.trending(kind: _kind)
          : await GiphyClient.instance
              .search(query: _query.text, kind: _kind);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on GiphyException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _load);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          children: [
            Row(
              children: [
                _StickerTab('Stickers', _kind == GiphyKind.stickers,
                    () => setState(() {
                          _kind = GiphyKind.stickers;
                          _load();
                        })),
                const SizedBox(width: 16),
                _StickerTab('GIPHY', _kind == GiphyKind.gifs, () {
                  setState(() {
                    _kind = GiphyKind.gifs;
                    _load();
                  });
                }),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: kBgSurface2,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search, color: kTextSecondary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _query,
                      style: const TextStyle(color: Colors.white),
                      cursorColor: kAccentCyan,
                      decoration: const InputDecoration(
                        hintText: 'Search GIPHY',
                        hintStyle: TextStyle(color: kTextSecondary),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      onChanged: _onQueryChanged,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kAccentCyan));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white, size: 32),
              onPressed: _load,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text('No results',
            style: TextStyle(color: kTextSecondary)),
      );
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: _items.length,
      itemBuilder: (_, i) {
        final it = _items[i];
        return InkWell(
          onTap: () => Navigator.pop(context, it),
          child: ColoredBox(
            color: kBgSurface2,
            child: Image.network(
              it.previewUrl,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image, color: Colors.red),
            ),
          ),
        );
      },
    );
  }
}

class _StickerTab extends StatelessWidget {
  const _StickerTab(this.label, this.active, this.onTap);
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                  color: active ? Colors.white : kTextSecondary,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
          const SizedBox(height: 2),
          Container(
            height: 2,
            width: 24,
            color: active ? kAccentCyan : Colors.transparent,
          ),
        ],
      ),
    );
  }
}

// ─── Export settings sheet ───────────────────────────────────────

Future<void> showExportSettingsSheet(
  BuildContext context,
  EditorState st, {
  required VoidCallback onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Export settings',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _StepSlider(
                label: 'Resolution',
                hint: 'Normal definition - uses less space, better for sharing',
                values: kResolutionPresets,
                value: st.export.resolution,
                suffix: 'P',
                onChanged: (v) {
                  st.export.resolution = v;
                  onChanged();
                  set(() {});
                },
              ),
              const SizedBox(height: 16),
              _StepSlider(
                label: 'Frame rate',
                hint: 'Smoother playback',
                values: kFramerates,
                value: st.export.frameRate,
                onChanged: (v) {
                  st.export.frameRate = v;
                  onChanged();
                  set(() {});
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Optical flow',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Switch(
                    value: st.export.opticalFlow,
                    activeThumbColor: kAccentCyan,
                    onChanged: (v) {
                      st.export.opticalFlow = v;
                      onChanged();
                      set(() {});
                    },
                  ),
                ],
              ),
              const Text('Make video playback smoother',
                  style: TextStyle(color: kTextSecondary, fontSize: 11)),
              const SizedBox(height: 16),
              _StepSlider(
                label: 'Bitrate (Mbps)',
                hint: 'Recommended for this video (${st.export.bitrate})',
                values: kBitratePresets,
                value: st.export.bitrate,
                onChanged: (v) {
                  st.export.bitrate = v;
                  onChanged();
                  set(() {});
                },
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Estimated file size: ${st.export.estimatedSizeMb(st.totalDurationMs ~/ 1000)} MB',
                  style: const TextStyle(color: kTextSecondary, fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccentCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: const Text('Export',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          letterSpacing: 0.2)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─── Caption template labels (used by auto-captions sheet) ───────

const List<String> _kCaptionTemplates = [
  'Bold White',
  'Yellow Box',
  'Neon Glow',
  'Minimal',
  'Karaoke',
];

// ─── Transition picker sheet ─────────────────────────────────────

Future<ClipTransition?> showTransitionPickerSheet(
  BuildContext context, {
  ClipTransition? current,
}) {
  TransitionType selected = current?.type ?? TransitionType.none;
  double durationSec = ((current?.durationMs ?? 500) / 1000.0).clamp(0.1, 2.0);
  bool applyToAll = false;

  return showModalBottomSheet<ClipTransition>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Spacer(),
                  const Text('Transition',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                  childAspectRatio: 1.0,
                ),
                itemCount: TransitionType.values.length,
                itemBuilder: (_, i) {
                  final t = TransitionType.values[i];
                  final isSel = t == selected;
                  return GestureDetector(
                    onTap: () => set(() => selected = t),
                    child: Container(
                      width: 84,
                      height: 84,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: kBgSurface2,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSel ? kAccentCyan : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFF4527A0),
                                    Color(0xFFE91E63),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (selected != TransitionType.none) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Duration',
                        style: TextStyle(color: Colors.white)),
                    const Spacer(),
                    Text('${durationSec.toStringAsFixed(1)} s',
                        style: const TextStyle(color: kAccentCyan)),
                  ],
                ),
                Slider(
                  value: durationSec,
                  min: 0.1,
                  max: 2.0,
                  activeColor: kAccentCyan,
                  onChanged: (v) => set(() => durationSec = v),
                ),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('Apply to all',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Switch(
                    value: applyToAll,
                    activeThumbColor: kAccentCyan,
                    onChanged: (v) => set(() => applyToAll = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                    ctx,
                    ClipTransition(
                      type: selected,
                      durationMs: (durationSec * 1000).round(),
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccentCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: const Text('Apply',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─── Animation sheet ─────────────────────────────────────────────

const List<String> _kAnimPresets = [
  'None',
  'Fade',
  'Slide',
  'Zoom',
  'Spin',
  'Mosaic',
];

Future<ClipAnimation?> showAnimationSheet(
  BuildContext context, {
  ClipAnimation? current,
}) {
  AnimDirection direction = current?.direction ?? AnimDirection.inAnim;
  String preset = current?.name ?? 'None';
  double durationSec = ((current?.durationMs ?? 600) / 1000.0).clamp(0.1, 3.0);

  return showModalBottomSheet<ClipAnimation>(
    context: context,
    backgroundColor: kBgSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Spacer(),
                  const Text('Animation',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _TabBtn('In', direction == AnimDirection.inAnim,
                      () => set(() => direction = AnimDirection.inAnim)),
                  const SizedBox(width: 16),
                  _TabBtn('Out', direction == AnimDirection.outAnim,
                      () => set(() => direction = AnimDirection.outAnim)),
                  const SizedBox(width: 16),
                  _TabBtn('Group', direction == AnimDirection.groupAnim,
                      () => set(() => direction = AnimDirection.groupAnim)),
                ],
              ),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 12),
              SizedBox(
                height: 90,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _kAnimPresets.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) {
                    final name = _kAnimPresets[i];
                    final isSel = name == preset;
                    return GestureDetector(
                      onTap: () => set(() => preset = name),
                      child: Column(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color(0xFF4527A0),
                                  Color(0xFFE91E63),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSel ? kAccentCyan : Colors.white24,
                                width: 2,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(name,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10)),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Duration',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text('${durationSec.toStringAsFixed(1)} s',
                      style: const TextStyle(color: kAccentCyan)),
                ],
              ),
              Slider(
                value: durationSec,
                min: 0.1,
                max: 3.0,
                activeColor: kAccentCyan,
                onChanged: (v) => set(() => durationSec = v),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(
                    ctx,
                    ClipAnimation(
                      name: preset,
                      direction: direction,
                      durationMs: (durationSec * 1000).round(),
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccentCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: const Text('Apply',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─── Success pill (snack) ────────────────────────────────────────

void showSuccessPill(BuildContext context, String text) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: kBgSurface,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 1500),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF4CAF50)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

class _StepSlider extends StatelessWidget {
  const _StepSlider({
    required this.label,
    required this.hint,
    required this.values,
    required this.value,
    required this.onChanged,
    this.suffix = '',
  });
  final String label;
  final String hint;
  final List<int> values;
  final int value;
  final ValueChanged<int> onChanged;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final idx = values.indexOf(value);
    final selectedIdx = idx < 0 ? 0 : idx;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 6),
            const Icon(Icons.help_outline, color: kTextSecondary, size: 14),
            const Spacer(),
            Text('${values[selectedIdx]}$suffix',
                style: const TextStyle(color: kAccentCyan)),
          ],
        ),
        Text(hint, style: const TextStyle(color: kTextSecondary, fontSize: 11)),
        Slider(
          value: selectedIdx.toDouble(),
          min: 0,
          max: (values.length - 1).toDouble(),
          divisions: values.length - 1,
          activeColor: kAccentCyan,
          onChanged: (v) => onChanged(values[v.round()]),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final v in values)
              Text('$v',
                  style: const TextStyle(color: kTextSecondary, fontSize: 9)),
          ],
        ),
      ],
    );
  }
}

// ─── Audio fade sheet ────────────────────────────────────────────

Future<bool?> showAudioFadeSheet(BuildContext context, AudioTrack t) {
  int fin = t.fadeInMs;
  int fout = t.fadeOutMs;
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Fade',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Fade in',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text('${fin}ms',
                      style: const TextStyle(
                          color: kTextSecondary,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
              Slider(
                value: fin.toDouble(),
                min: 0,
                max: 5000,
                divisions: 50,
                activeColor: kAccentCyan,
                onChanged: (v) => set(() => fin = v.round()),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('Fade out',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text('${fout}ms',
                      style: const TextStyle(
                          color: kTextSecondary,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
              Slider(
                value: fout.toDouble(),
                min: 0,
                max: 5000,
                divisions: 50,
                activeColor: kAccentCyan,
                onChanged: (v) => set(() => fout = v.round()),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      t.fadeInMs = fin;
                      t.fadeOutMs = fout;
                      Navigator.pop(ctx, true);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccentCyan,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 8),
                    ),
                    child: const Text('Apply',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─── Text animation sheet ────────────────────────────────────────

Future<bool?> showTextAnimationSheet(BuildContext context, TextOverlay t) {
  const animations = ['None', 'Fade', 'Slide', 'Zoom', 'Bounce', 'Typewriter', 'Pop'];
  AnimDirection dir = t.animationDirection;
  String name = t.animationName ?? 'None';
  int dur = t.animationDurationMs;
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Text animation',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final d in AnimDirection.values)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: GestureDetector(
                          onTap: () => set(() => dir = d),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: dir == d ? kAccentCyan : kBgSurface2,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            alignment: Alignment.center,
                            child: Text(d.label,
                                style: TextStyle(
                                    color: dir == d ? Colors.black : Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final a in animations)
                    GestureDetector(
                      onTap: () => set(() => name = a),
                      child: Container(
                        width: 86,
                        height: 64,
                        decoration: BoxDecoration(
                          color: kBgSurface2,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: name == a ? kAccentCyan : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              a == 'None'
                                  ? Icons.block
                                  : Icons.auto_awesome,
                              color: name == a ? kAccentCyan : Colors.white,
                              size: 20,
                            ),
                            const SizedBox(height: 4),
                            Text(a,
                                style: TextStyle(
                                    color: name == a ? kAccentCyan : Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Duration',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text('${dur}ms',
                      style: const TextStyle(
                          color: kTextSecondary,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
              Slider(
                value: dur.toDouble(),
                min: 300,
                max: 2000,
                divisions: 17,
                activeColor: kAccentCyan,
                onChanged: (v) => set(() => dur = v.round()),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    t.animationName = name == 'None' ? null : name;
                    t.animationDirection = dir;
                    t.animationDurationMs = dur;
                    Navigator.pop(ctx, true);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccentCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                  ),
                  child: const Text('Apply',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─── Stabilize sheet ─────────────────────────────────────────────

Future<String?> showStabilizeSheet(BuildContext context,
    {String current = 'medium'}) {
  const options = [
    ('off', 'Off'),
    ('low', 'Low'),
    ('medium', 'Medium'),
    ('high', 'High'),
  ];
  String sel = current;
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Stabilize',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Text('Reduce camera shake. Higher = more crop.',
                  style: TextStyle(color: kTextSecondary, fontSize: 12)),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (final o in options)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: GestureDetector(
                          onTap: () => set(() => sel = o.$1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: sel == o.$1 ? kAccentCyan : kBgSurface2,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            alignment: Alignment.center,
                            child: Text(o.$2,
                                style: TextStyle(
                                    color: sel == o.$1
                                        ? Colors.black
                                        : Colors.white,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, sel),
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccentCyan,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 8),
                    ),
                    child: const Text('Apply',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─── Mask sheet ──────────────────────────────────────────────────

Future<bool?> showMaskSheet(BuildContext context, ClipSegment seg) {
  const shapes = [
    ('none', 'None', Icons.block),
    ('rect', 'Rectangle', Icons.crop_square),
    ('circle', 'Circle', Icons.circle_outlined),
    ('heart', 'Heart', Icons.favorite_border),
    ('star', 'Star', Icons.star_border),
    ('triangle', 'Triangle', Icons.change_history),
  ];
  String shape = seg.maskShape;
  double feather = seg.maskFeather;
  bool inverted = seg.maskInverted;
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Mask',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final s in shapes)
                    GestureDetector(
                      onTap: () => set(() => shape = s.$1),
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: kBgSurface2,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: shape == s.$1
                                ? kAccentCyan
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(s.$3,
                            color: shape == s.$1 ? kAccentCyan : Colors.white,
                            size: 28),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Feather',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text((feather * 100).toStringAsFixed(0),
                      style: const TextStyle(color: kTextSecondary)),
                ],
              ),
              Slider(
                value: feather,
                min: 0,
                max: 1,
                activeColor: kAccentCyan,
                onChanged: (v) => set(() => feather = v),
              ),
              Row(
                children: [
                  const Text('Invert',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Switch(
                    value: inverted,
                    activeThumbColor: kAccentCyan,
                    onChanged: (v) => set(() => inverted = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    seg.maskShape = shape;
                    seg.maskFeather = feather;
                    seg.maskInverted = inverted;
                    Navigator.pop(ctx, true);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccentCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                  ),
                  child: const Text('Apply',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ─── Chroma key sheet ────────────────────────────────────────────

Future<bool?> showChromaSheet(BuildContext context, ClipSegment seg) {
  const palette = <Color>[
    Color(0xFF00FF00),
    Color(0xFF0000FF),
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FFFF),
    Color(0xFFFF00FF),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
  ];
  Color? key = seg.chromaKeyColor;
  double tol = seg.chromaTolerance;
  double soft = seg.chromaSoftness;
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: kBgSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Chroma key',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Text('Pick a color to make transparent.',
                  style: TextStyle(color: kTextSecondary, fontSize: 12)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  GestureDetector(
                    onTap: () => set(() => key = null),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: kBgSurface2,
                        borderRadius: BorderRadius.circular(21),
                        border: Border.all(
                          color: key == null ? kAccentCyan : Colors.white24,
                          width: 2,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.block,
                          color: Colors.white, size: 20),
                    ),
                  ),
                  for (final c in palette)
                    GestureDetector(
                      onTap: () => set(() => key = c),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: key?.toARGB32() == c.toARGB32()
                                ? kAccentCyan
                                : Colors.white24,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Tolerance',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text((tol * 100).toStringAsFixed(0),
                      style: const TextStyle(color: kTextSecondary)),
                ],
              ),
              Slider(
                value: tol,
                min: 0,
                max: 1,
                activeColor: kAccentCyan,
                onChanged: (v) => set(() => tol = v),
              ),
              Row(
                children: [
                  const Text('Softness',
                      style: TextStyle(color: Colors.white)),
                  const Spacer(),
                  Text((soft * 100).toStringAsFixed(0),
                      style: const TextStyle(color: kTextSecondary)),
                ],
              ),
              Slider(
                value: soft,
                min: 0,
                max: 1,
                activeColor: kAccentCyan,
                onChanged: (v) => set(() => soft = v),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    seg.chromaKeyColor = key;
                    seg.chromaTolerance = tol;
                    seg.chromaSoftness = soft;
                    Navigator.pop(ctx, true);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccentCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28)),
                  ),
                  child: const Text('Apply',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
