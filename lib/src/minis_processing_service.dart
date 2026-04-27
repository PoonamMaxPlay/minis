import 'dart:async';
import 'dart:io';
import 'package:loopit_minis/src/independent/minis_multiclip_merge.dart';
import 'package:loopit_minis/src/minis_handoff.dart';

/// A service to handle high-level video processing tasks for the Minis flow.
abstract final class MinisProcessingService {
  /// Processes a [MinisHandoffRequest] by merging or transcoding as needed.
  ///
  /// Returns the final processed file path, or `null` if processing was cancelled or failed.
  static Future<String?> processRequest(MinisHandoffRequest request) async {
    if (request.action == MinisHandoffAction.none) {
      return request.path;
    }

    if (request.action == MinisHandoffAction.mergeRequired) {
      return mergeMinisVideoClipsSilent(
        clipPaths: request.clipPaths,
        playbackSpeed: request.playbackSpeed,
        enableAudio: request.enableAudio,
        backgroundMusic: request.backgroundMusic,
      );
    }

    return null;
  }

  /// Utility to clean up temporary files created during Minis capture.
  static Future<void> cleanupTemporaryClips(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Best effort cleanup
      }
    }
  }
}
