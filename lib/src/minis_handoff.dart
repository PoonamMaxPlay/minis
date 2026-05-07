import 'package:loopit_minis/src/independent/minis_music_segment.dart';

/// Defines the type of handoff action requested by the Minis plugin.
enum MinisHandoffAction {
  /// The clips need to be merged/processed by the host app.
  mergeRequired,

  /// The capture is complete and the raw file path is provided.
  none,
}

/// A typed model for the handoff from the Minis plugin to the host application.
class MinisHandoffRequest {
  const MinisHandoffRequest({
    required this.action,
    this.path,
    this.clipPaths = const [],
    this.playbackSpeed = 1.0,
    this.enableAudio = true,
    this.backgroundMusic,
  });

  /// The primary action requested.
  final MinisHandoffAction action;

  /// The path to a single video file (if [action] is [MinisHandoffAction.none]).
  final String? path;

  /// The paths to multiple segments to be merged (if [action] is [MinisHandoffAction.mergeRequired]).
  final List<String> clipPaths;

  /// The playback speed for the merged video.
  final double playbackSpeed;

  /// Whether the original clip audio should be enabled.
  final bool enableAudio;

  /// Optional background music segment to be mixed in.
  final MinisMusicSegment? backgroundMusic;

  /// Factory to create a request from the legacy Map format (internal use).
  factory MinisHandoffRequest.fromMap(Map<String, dynamic> map) {
    final actionStr = map['minis_action'] as String?;
    final action = actionStr == 'merge_required'
        ? MinisHandoffAction.mergeRequired
        : MinisHandoffAction.none;

    return MinisHandoffRequest(
      action: action,
      path: map['path'] as String?,
      clipPaths: (map['clipPaths'] as List?)?.cast<String>() ?? [],
      playbackSpeed: (map['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
      enableAudio: map['enableAudio'] as bool? ?? true,
      backgroundMusic: map['backgroundMusic'] is MinisMusicSegment
          ? map['backgroundMusic'] as MinisMusicSegment
          : map['backgroundMusic'] is Map
              ? MinisMusicSegment.fromMap(
                  Map<String, dynamic>.from(map['backgroundMusic'] as Map))
              : null,
    );
  }

  /// Converts the request to the legacy Map format (internal use).
  Map<String, dynamic> toMap() {
    return {
      'minis_action':
          action == MinisHandoffAction.mergeRequired ? 'merge_required' : 'none',
      'path': path,
      'clipPaths': clipPaths,
      'playbackSpeed': playbackSpeed,
      'enableAudio': enableAudio,
      'backgroundMusic': backgroundMusic,
    };
  }
}
