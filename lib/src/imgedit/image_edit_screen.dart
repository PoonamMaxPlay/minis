import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:loopit_minis/src/sys/paths.dart';

import 'emoji_picker_view.dart';
import 'image_edit_channel.dart';
import 'image_edit_layer_types.dart';
import 'image_edit_view.dart';

/// Full-screen editor route. Hosts the native render surface, owns the
/// tool dock, and brokers undo/redo + export.
///
/// While the native pipeline is still skeleton-only the Dart side keeps
/// the round-trip alive: if `exportImage` returns a path the caller gets
/// that; if it errors / returns empty the screen falls back to the source
/// path (or freshly-written bytes for memory-init), so dependent flows
/// (overlay export, gallery edit) remain functional.
class MinisImageEditScreen extends StatefulWidget {
  const MinisImageEditScreen({
    super.key,
    required this.sourcePath,
    this.fallbackBytes,
    this.exportFormat = MinisImageExportFormat.jpeg,
    this.exportQuality = 92,
    this.exportMaxDim,
    this.title = 'Edit image',
  });

  /// Opens the editor from a file path, returns the saved output path
  /// (or null when the user cancels / save fails).
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

  /// Opens the editor from in-memory bytes (used for blank-canvas overlay
  /// creation). The bytes are persisted to a temp file so the native side
  /// can decode by path uniformly.
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
  int? _viewId;
  bool _busy = false;
  bool _canUndo = false;
  bool _canRedo = false;
  StreamSubscription<MinisImageEditEvent>? _stateSub;

  @override
  void initState() {
    super.initState();
    _stateSub = _channel.events.listen((_) {
      if (!mounted) return;
      setState(() {});
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    final id = _viewId;
    if (id != null) {
      unawaited(_channel.dispose(viewId: id));
    }
    super.dispose();
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

  Future<void> _undo() async {
    final id = _viewId;
    if (id == null) return;
    try {
      final state = await _channel.undo(viewId: id);
      if (!mounted) return;
      setState(() {
        _canUndo = state.canUndo;
        _canRedo = state.canRedo;
      });
    } catch (_) {}
  }

  Future<void> _redo() async {
    final id = _viewId;
    if (id == null) return;
    try {
      final state = await _channel.redo(viewId: id);
      if (!mounted) return;
      setState(() {
        _canUndo = state.canUndo;
        _canRedo = state.canRedo;
      });
    } catch (_) {}
  }

  Future<String> _passthroughExportPath() async {
    final basePath = await NativePaths.documentsDir();
    if (basePath == null) return widget.sourcePath;
    final dir = Directory(NativePaths.join([basePath, 'loopit_minis_captures']));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final out = NativePaths.join([
      dir.path,
      'minis_imgedit_${DateTime.now().microsecondsSinceEpoch}.'
      '${widget.exportFormat.fileExtension}',
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
          format: widget.exportFormat,
          quality: widget.exportQuality,
          maxDim: widget.exportMaxDim,
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

  void _cancel() {
    Navigator.of(context).pop();
  }

  Future<void> _openEmojiPicker() async {
    final id = _viewId;
    if (id == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black,
      isScrollControlled: true,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.55,
        child: MinisEmojiPicker(
          onSelected: (cp) async {
            try {
              await _channel.placeEmoji(
                viewId: id,
                codePoint: cp.toString(),
                transform: const MinisImageTransform(tx: 0.5, ty: 0.5),
              );
            } catch (_) {}
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _busy ? null : _cancel,
        ),
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.emoji_emotions_outlined),
            onPressed: _busy || _viewId == null ? null : _openEmojiPicker,
          ),
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: _canUndo && !_busy ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            onPressed: _canRedo && !_busy ? _redo : null,
          ),
          IconButton(
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check),
            onPressed: _busy ? null : _save,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            MinisImageEditPlatformView(
              sourcePath: widget.sourcePath,
              onPlatformViewCreated: _onPlatformViewCreated,
            ),
            if (_viewId == null)
              const Center(
                child: CircularProgressIndicator(color: Colors.white70),
              ),
          ],
        ),
      ),
    );
  }
}
