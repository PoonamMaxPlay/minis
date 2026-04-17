import 'dart:typed_data';

/// One recorded video segment in a multi-clip Minis session (LoopIt-style reel).
class MinisRecordingClip {
  const MinisRecordingClip({
    required this.id,
    required this.path,
    required this.durationMs,
    this.thumbnailBytes,
    this.speedAtRecord = 1.0,
  });

  /// Stable unique id for list keys (camera temp paths may repeat across takes).
  final int id;
  final String path;
  final int durationMs;
  final Uint8List? thumbnailBytes;

  /// Playback speed selected when this clip was recorded or appended.
  /// Stored so that future per-clip speed mixing can apply the correct rate
  /// rather than using the speed set at merge time for all clips.
  final double speedAtRecord;
}
