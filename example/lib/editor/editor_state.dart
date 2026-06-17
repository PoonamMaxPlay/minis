import 'package:flutter/material.dart';

enum AspectMode { original, r9x16, r16x9, r1x1, r4x3, r3x4, r5x8 }

extension AspectModeX on AspectMode {
  double get ratio {
    switch (this) {
      case AspectMode.original:
        return 0;
      case AspectMode.r9x16:
        return 9 / 16;
      case AspectMode.r16x9:
        return 16 / 9;
      case AspectMode.r1x1:
        return 1.0;
      case AspectMode.r4x3:
        return 4 / 3;
      case AspectMode.r3x4:
        return 3 / 4;
      case AspectMode.r5x8:
        return 5 / 8;
    }
  }

  String get label {
    switch (this) {
      case AspectMode.original:
        return 'Original';
      case AspectMode.r9x16:
        return '9:16';
      case AspectMode.r16x9:
        return '16:9';
      case AspectMode.r1x1:
        return '1:1';
      case AspectMode.r4x3:
        return '4:3';
      case AspectMode.r3x4:
        return '3:4';
      case AspectMode.r5x8:
        return '5.8"';
    }
  }
}

enum BackgroundMode { none, color, image, blur }

enum FilterPreset { none, bw, sepia, warm, cool, vivid, fade, drama, mono, vintage }

extension FilterPresetX on FilterPreset {
  String get label {
    switch (this) {
      case FilterPreset.none:
        return 'None';
      case FilterPreset.bw:
        return 'B&W';
      case FilterPreset.sepia:
        return 'Sepia';
      case FilterPreset.warm:
        return 'Warm';
      case FilterPreset.cool:
        return 'Cool';
      case FilterPreset.vivid:
        return 'Vivid';
      case FilterPreset.fade:
        return 'Fade';
      case FilterPreset.drama:
        return 'Drama';
      case FilterPreset.mono:
        return 'Mono';
      case FilterPreset.vintage:
        return 'Vintage';
    }
  }
}

abstract class Overlay {
  final String id;
  Offset position;
  double scale;
  double rotation;
  bool flipH;
  int startMs;
  int endMs;
  Overlay({
    required this.id,
    required this.position,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.flipH = false,
    this.startMs = 0,
    this.endMs = 0x7fffffff,
  });

  bool visibleAt(int ms) => ms >= startMs && ms <= endMs;
}

class TextOverlay extends Overlay {
  String text;
  double fontSize;
  Color color;
  Color? bgColor;
  bool bold;
  bool italic;
  String fontFamily;
  TextAlign align;
  String? animationName;
  AnimDirection animationDirection;
  int animationDurationMs;
  int lane;
  bool hidden;
  Offset? endPosition;

  TextOverlay({
    required super.id,
    required this.text,
    super.position = const Offset(0.5, 0.4),
    super.scale,
    super.rotation,
    super.flipH,
    super.startMs,
    super.endMs,
    this.fontSize = 36,
    this.color = Colors.white,
    this.bgColor,
    this.bold = false,
    this.italic = false,
    this.fontFamily = 'Roboto',
    this.align = TextAlign.center,
    this.animationName,
    this.animationDirection = AnimDirection.inAnim,
    this.animationDurationMs = 600,
    this.lane = 0,
    this.hidden = false,
    this.endPosition,
  });
}

class StickerOverlay extends Overlay {
  final String url;
  final double aspect;
  final bool isGif;

  StickerOverlay({
    required super.id,
    required this.url,
    required this.aspect,
    this.isGif = true,
    super.position = const Offset(0.5, 0.5),
    super.scale = 0.4,
    super.rotation,
    super.flipH,
    super.startMs,
    super.endMs,
  });
}

class DrawStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  const DrawStroke({
    required this.points,
    required this.color,
    required this.width,
  });
}

class AudioTrack {
  final String id;
  final String path;
  final String label;
  int startMs;
  int inMs;
  int outMs;
  double volume;
  bool ducking;
  int fadeInMs;
  int fadeOutMs;
  bool muted;
  bool normalize;
  AudioTrack({
    required this.id,
    required this.path,
    required this.label,
    this.startMs = 0,
    this.inMs = 0,
    this.outMs = 0x7fffffff,
    this.volume = 1.0,
    this.ducking = false,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
    this.muted = false,
    this.normalize = false,
  });

  double get effectiveVolume => muted ? 0.0 : volume;
}

class Caption {
  final String id;
  String text;
  int startMs;
  int endMs;
  Caption({
    required this.id,
    required this.text,
    required this.startMs,
    required this.endMs,
  });
}

enum TransitionType { none, crossfade, slide, push, zoomDissolve, glitch }

extension TransitionTypeX on TransitionType {
  String get label {
    switch (this) {
      case TransitionType.none:
        return 'None';
      case TransitionType.crossfade:
        return 'Crossfade';
      case TransitionType.slide:
        return 'Slide';
      case TransitionType.push:
        return 'Push';
      case TransitionType.zoomDissolve:
        return 'Zoom Dissolve';
      case TransitionType.glitch:
        return 'Glitch';
    }
  }
}

class ClipTransition {
  final TransitionType type;
  final int durationMs;
  const ClipTransition({
    required this.type,
    this.durationMs = 500,
  });
}

enum AnimDirection { inAnim, outAnim, groupAnim }

extension AnimDirectionX on AnimDirection {
  String get label {
    switch (this) {
      case AnimDirection.inAnim:
        return 'In';
      case AnimDirection.outAnim:
        return 'Out';
      case AnimDirection.groupAnim:
        return 'Group';
    }
  }
}

class ClipAnimation {
  final String name;
  final AnimDirection direction;
  final int durationMs;
  const ClipAnimation({
    required this.name,
    required this.direction,
    this.durationMs = 600,
  });
}

class ClipSegment {
  final String id;
  int inMs;
  int outMs;
  double speed;
  bool muted;
  ClipTransition? transitionOut;
  ClipAnimation? animation;
  String maskShape;
  double maskFeather;
  bool maskInverted;
  Color? chromaKeyColor;
  double chromaTolerance;
  double chromaSoftness;
  String? stabilizeMode;
  bool reversed;
  ClipSegment({
    required this.id,
    required this.inMs,
    required this.outMs,
    this.speed = 1.0,
    this.muted = false,
    this.transitionOut,
    this.animation,
    this.maskShape = 'none',
    this.maskFeather = 0.0,
    this.maskInverted = false,
    this.chromaKeyColor,
    this.chromaTolerance = 0.3,
    this.chromaSoftness = 0.2,
    this.stabilizeMode,
    this.reversed = false,
  });

  int get durationMs => ((outMs - inMs) / speed).round();
}

class ExportSettings {
  int resolution;
  int frameRate;
  bool opticalFlow;
  int bitrate;
  ExportSettings({
    this.resolution = 540,
    this.frameRate = 30,
    this.opticalFlow = false,
    this.bitrate = 7,
  });

  int estimatedSizeMb(int durationSec) {
    return (bitrate * durationSec / 8).round();
  }
}

class EditorAdjust {
  double brightness;
  double contrast;
  double saturation;
  double brilliance;
  double sharpen;
  double clarity;
  double temperature;
  double tint;
  double vibrance;
  EditorAdjust({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.brilliance = 0,
    this.sharpen = 0,
    this.clarity = 0,
    this.temperature = 0,
    this.tint = 0,
    this.vibrance = 0,
  });

  void reset() {
    brightness = contrast = saturation = brilliance = sharpen = clarity = 0;
    temperature = tint = vibrance = 0;
  }
}

class EditorState extends ChangeNotifier {
  String videoPath;
  int totalDurationMs = 0;
  AspectMode aspect = AspectMode.original;
  BackgroundMode bgMode = BackgroundMode.none;
  Color bgColor = Colors.black;
  String? bgImagePath;
  FilterPreset filter = FilterPreset.none;
  double filterIntensity = 1.0;
  EditorAdjust adjust = EditorAdjust();
  bool clipMuted = false;
  bool videoHidden = false;
  bool audioHidden = false;
  bool captionsHidden = false;
  bool stickersHidden = false;
  // Order of non-video lanes top-to-bottom. Video lane is locked at top and
  // not present in this list.
  List<String> laneOrder = ['text', 'audio', 'captions', 'stickers'];
  double clipSpeed = 1.0;
  double clipVolume = 1.0;
  int coverMs = 0;
  bool keepMusicTempo = true;
  bool snapEnabled = true;
  bool transformMode = false;
  bool suggestionDismissed = false;
  bool isPlaying = false;
  bool showSafeZones = false;
  bool showGrid = false;
  bool proxyMode = false;
  bool showFps = false;
  int frameRateHint = 30;

  final List<ClipSegment> clips = [];
  final List<TextOverlay> texts = [];
  final List<StickerOverlay> stickers = [];
  final List<DrawStroke> strokes = [];
  final List<AudioTrack> audios = [];
  final List<Caption> captions = [];

  ExportSettings export = ExportSettings();

  bool commitCancelMode = false;
  double timelinePxPerMs = 0.06;
  double timelineVertScroll = 0.0;

  final ValueNotifier<int> positionNotifier = ValueNotifier<int>(0);
  final ValueNotifier<EditorSelection> selectionNotifier =
      ValueNotifier<EditorSelection>(const EditorSelection());

  int get positionMs => positionNotifier.value;
  set positionMs(int v) {
    if (positionNotifier.value != v) positionNotifier.value = v;
  }

  String? get selectedOverlayId => selectionNotifier.value.overlayId;
  set selectedOverlayId(String? v) {
    final s = selectionNotifier.value;
    if (s.overlayId != v) {
      selectionNotifier.value = s.copyWith(overlayId: v, clearOverlay: v == null);
    }
  }

  String? get selectedClipId => selectionNotifier.value.clipId;
  set selectedClipId(String? v) {
    final s = selectionNotifier.value;
    if (s.clipId != v) {
      selectionNotifier.value = s.copyWith(clipId: v, clearClip: v == null);
    }
  }

  String? get selectedSegmentId => selectionNotifier.value.segmentId;
  set selectedSegmentId(String? v) {
    final s = selectionNotifier.value;
    if (s.segmentId != v) {
      selectionNotifier.value =
          s.copyWith(segmentId: v, clearSegment: v == null);
    }
  }

  String? get selectedSegmentKind => selectionNotifier.value.segmentKind;
  set selectedSegmentKind(String? v) {
    final s = selectionNotifier.value;
    if (s.segmentKind != v) {
      selectionNotifier.value =
          s.copyWith(segmentKind: v, clearSegmentKind: v == null);
    }
  }

  EditorState({required this.videoPath});

  @override
  void dispose() {
    positionNotifier.dispose();
    selectionNotifier.dispose();
    super.dispose();
  }

  void notify() => notifyListeners();

  // Sequential append: place new audio after last audio's end (or at 0).
  int nextAudioStartMs() {
    if (audios.isEmpty) return 0;
    var maxEnd = 0;
    for (final a in audios) {
      final dur = (a.outMs == 0x7fffffff) ? totalDurationMs : (a.outMs - a.inMs);
      final end = a.startMs + dur;
      if (end > maxEnd) maxEnd = end;
    }
    return maxEnd;
  }

  // Next free lane for a new text overlay.
  int nextTextLane() {
    if (texts.isEmpty) return 0;
    var maxLane = -1;
    for (final t in texts) {
      if (t.lane > maxLane) maxLane = t.lane;
    }
    return maxLane + 1;
  }

  void moveTextToLane(String id, int lane) {
    for (final t in texts) {
      if (t.id == id) {
        if (t.lane != lane) {
          t.lane = lane;
          notify();
        }
        return;
      }
    }
  }

  void toggleLaneVisibility(int lane) {
    final anyVisible = texts.where((t) => t.lane == lane && !t.hidden).isNotEmpty;
    for (final t in texts) {
      if (t.lane == lane) t.hidden = anyVisible;
    }
    notify();
  }

  bool laneIsHidden(int lane) {
    final laneTexts = texts.where((t) => t.lane == lane);
    if (laneTexts.isEmpty) return false;
    return laneTexts.every((t) => t.hidden);
  }

  void toggleAudioMute(String id) {
    for (final a in audios) {
      if (a.id == id) {
        a.muted = !a.muted;
        notify();
        return;
      }
    }
  }

  bool get anyAudioMuted => audios.any((a) => a.muted);

  void muteAllAudio(bool muted) {
    for (final a in audios) {
      a.muted = muted;
    }
    notify();
  }

  void setVideoHidden(bool v) {
    if (videoHidden == v) return;
    videoHidden = v;
    notify();
  }

  void setAudioHidden(bool v) {
    if (audioHidden == v) return;
    audioHidden = v;
    // Mute side-effect: hide also mutes so playback respects the toggle.
    if (v) muteAllAudio(true);
    notify();
  }

  void setCaptionsHidden(bool v) {
    if (captionsHidden == v) return;
    captionsHidden = v;
    notify();
  }

  void setStickersHidden(bool v) {
    if (stickersHidden == v) return;
    stickersHidden = v;
    notify();
  }

  void reorderClips(int from, int to) {
    if (from < 0 || from >= clips.length) return;
    if (from == to) return;
    final c = clips.removeAt(from);
    final insertAt = to > from ? to - 1 : to;
    clips.insert(insertAt.clamp(0, clips.length), c);
    // Re-pack durations sequentially from 0 so the timeline reflects the new
    // ordering without gaps.
    var t = 0;
    for (final cl in clips) {
      final dur = cl.outMs - cl.inMs;
      cl.inMs = t;
      cl.outMs = t + dur;
      t = cl.outMs;
    }
    notify();
  }

  void reorderLanes(int oldIdx, int newIdx) {
    if (oldIdx < 0 || oldIdx >= laneOrder.length) return;
    final clamped = newIdx.clamp(0, laneOrder.length);
    final item = laneOrder.removeAt(oldIdx);
    laneOrder.insert(clamped > laneOrder.length ? laneOrder.length : clamped, item);
    notify();
  }
}

class EditorSelection {
  final String? overlayId;
  final String? clipId;
  final String? segmentId;
  final String? segmentKind;
  const EditorSelection({
    this.overlayId,
    this.clipId,
    this.segmentId,
    this.segmentKind,
  });
  EditorSelection copyWith({
    String? overlayId,
    String? clipId,
    String? segmentId,
    String? segmentKind,
    bool clearOverlay = false,
    bool clearClip = false,
    bool clearSegment = false,
    bool clearSegmentKind = false,
  }) {
    return EditorSelection(
      overlayId: clearOverlay ? null : (overlayId ?? this.overlayId),
      clipId: clearClip ? null : (clipId ?? this.clipId),
      segmentId: clearSegment ? null : (segmentId ?? this.segmentId),
      segmentKind:
          clearSegmentKind ? null : (segmentKind ?? this.segmentKind),
    );
  }
}

extension TextOverlayDurationX on TextOverlay {
  int get durationMs => endMs - startMs;
  set durationMs(int value) {
    endMs = startMs + value;
  }
}
