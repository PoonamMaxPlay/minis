import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:loopit_minis/src/independent/minis_video_preview_page.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// Extensions shown in the Sounds picker (`FileType.custom` filters the UI).
const List<String> kMinisAudioFileExtensions = [
  'mp3',
  'm4a',
  'aac',
  'wav',
  'ogg',
  'opus',
  'flac',
  'aiff',
  'aif',
  'wma',
  'amr',
];

bool minisPathLooksLikeAudio(String path) {
  final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
  return kMinisAudioFileExtensions.contains(ext);
}

/// Writes under app documents (same durable root as Minis capture handoff),
/// not [getTemporaryDirectory], so the host can copy/read the file after routes pop.
Future<String> _writeEditedJpeg(Uint8List bytes) async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(base.path, 'loopit_minis_captures'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final out = p.join(
    dir.path,
    'minis_pro_edit_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  await File(out).writeAsBytes(bytes, flush: true);
  return out;
}

/// Full-screen [ProImageEditor] (paint, text, crop, tune, filter, blur). The
/// editor checkmark writes a JPEG and this returns its path; cancel returns
/// null.
Future<String?> openMinisProImageEditor(
  BuildContext context,
  String imagePath,
) {
  final file = File(imagePath);
  if (!file.existsSync()) {
    return Future.value(null);
  }

  bool _popped = false;

  return Navigator.of(context, rootNavigator: true).push<String?>(
    MaterialPageRoute<String?>(
      fullscreenDialog: true,
      builder: (editorCtx) => ProImageEditor.file(
        file,
        configs: const ProImageEditorConfigs(
          imageGeneration: ImageGenerationConfigs(
            outputFormat: OutputFormat.jpg,
            jpegQuality: 92,
          ),
        ),
        callbacks: ProImageEditorCallbacks(
          onImageEditingComplete: (Uint8List bytes) async {
            try {
              final out = await _writeEditedJpeg(bytes);
              if (!_popped && editorCtx.mounted) {
                _popped = true;
                Navigator.of(editorCtx).pop(out);
              }
            } catch (_) {
              if (!_popped && editorCtx.mounted) {
                _popped = true;
                Navigator.of(editorCtx).pop();
              }
            }
          },
          onCloseEditor: () {
            if (!_popped && editorCtx.mounted) {
              _popped = true;
              Navigator.of(editorCtx).pop();
            }
          },
        ),
      ),
    ),
  );
}

/// Opens [MinisVideoPreviewPage] (play, scrub, optional trim, confirm).
Future<MinisVideoPreviewResult?> openMinisVideoPreview(
  BuildContext context,
  String videoPath, {
  bool allowReelTrim = false,
}) {
  return MinisVideoPreviewPage.open(
    context,
    videoPath,
    allowReelTrim: allowReelTrim,
  );
}
