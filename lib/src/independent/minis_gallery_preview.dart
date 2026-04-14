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

Future<String> _writeEditedJpeg(Uint8List bytes) async {
  final dir = await getTemporaryDirectory();
  final out = p.join(
    dir.path,
    'minis_pro_edit_${DateTime.now().millisecondsSinceEpoch}.jpg',
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

  return Navigator.of(context).push<String?>(
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
              if (editorCtx.mounted) {
                Navigator.of(editorCtx).pop(out);
              }
            } catch (_) {
              if (editorCtx.mounted) Navigator.of(editorCtx).pop();
            }
          },
          onCloseEditor: () {
            if (editorCtx.mounted) Navigator.of(editorCtx).pop();
          },
        ),
      ),
    ),
  );
}

/// Opens [MinisVideoPreviewPage] (play, scrub, optional trim, confirm).
Future<String?> openMinisVideoPreview(
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
