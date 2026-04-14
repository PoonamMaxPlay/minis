import 'dart:typed_data';

/// One recorded video segment in a multi-clip Minis session (LoopIt-style reel).
class MinisRecordingClip {
  const MinisRecordingClip({
    required this.path,
    required this.durationMs,
    this.thumbnailBytes,
  });

  final String path;
  final int durationMs;
  final Uint8List? thumbnailBytes;
}
