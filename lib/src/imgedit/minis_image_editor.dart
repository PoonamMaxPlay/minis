import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'image_edit_layer_types.dart';
import 'image_edit_screen.dart';

/// Public entry — replaces direct `ProImageEditor` use in Minis. Returns the
/// edited image path (or null on cancel / failure). Backed by the native
/// pipeline registered under `loopit/minis/imgedit`.
class MinisImageEditor {
  const MinisImageEditor._();

  static Future<String?> openFromFile(
    BuildContext context,
    String imagePath, {
    MinisImageExportFormat format = MinisImageExportFormat.jpeg,
    int quality = 92,
    int? maxDim,
  }) {
    return MinisImageEditScreen.openFromFile(
      context,
      imagePath,
      format: format,
      quality: quality,
      maxDim: maxDim,
    );
  }

  static Future<String?> openFromMemory(
    BuildContext context,
    Uint8List bytes, {
    MinisImageExportFormat format = MinisImageExportFormat.jpeg,
    int quality = 92,
    int? maxDim,
  }) {
    return MinisImageEditScreen.openFromMemory(
      context,
      bytes,
      format: format,
      quality: quality,
      maxDim: maxDim,
    );
  }
}
