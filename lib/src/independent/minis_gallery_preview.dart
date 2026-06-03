import 'dart:io';

import 'package:flutter/material.dart';
import 'package:loopit_minis/src/sys/paths.dart';
import 'package:loopit_minis/src/independent/minis_video_preview_page.dart';
import 'package:loopit_minis/src/imgedit/minis_image_editor.dart';

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
  final ext = NativePaths.extension(path).toLowerCase().replaceFirst('.', '');
  return kMinisAudioFileExtensions.contains(ext);
}

/// Full-screen native image editor (paint, text, crop, tune, filter, blur,
/// stickers, emoji, beauty). On save the native pipeline writes a JPEG to
/// app documents and the path is returned; cancel returns null.
Future<String?> openMinisProImageEditor(
  BuildContext context,
  String imagePath,
) {
  final file = File(imagePath);
  if (!file.existsSync()) {
    return Future.value(null);
  }
  return MinisImageEditor.openFromFile(context, imagePath);
}

/// Opens [MinisVideoPreviewPage] (play, scrub, optional trim, confirm).
Future<MinisVideoPreviewResult?> openMinisVideoPreview(
  BuildContext context,
  String videoPath, {
  bool allowReelTrim = false,
  int? initialTotalDurationMs,
}) {
  return MinisVideoPreviewPage.open(
    context,
    [videoPath],
    allowReelTrim: allowReelTrim,
    initialTotalDurationMs: initialTotalDurationMs,
  );
}
