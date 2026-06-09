import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editor_config.dart';
import 'editor_state.dart';
import 'editor_waveform.dart';

bool _inViewport(int startMs, int endMs, (int, int) range) {
  return endMs >= range.$1 && startMs <= range.$2;
}

const double kTrackHeight = 36;
const double kTrackGap = 4;
const double kRulerHeight = 18;
const double kSidePadding = 12;
const double kGutterWidth = 44;
const double kSnapTolerancePx = 8;

/// Multi-track timeline: ruler + video strip + N text lanes + sequential audio
/// lane. Time-positioned (px = ms * pxPerMs). Tap = seek. Drag X = move in
/// time. Drag Y on text = change lane (z-order). Snaps to playhead and clip
/// edges within tolerance.
class MultiTrackTimeline extends StatefulWidget {
  const MultiTrackTimeline({
    super.key,
    required this.state,
    required this.thumbs,
    required this.thumbsLoading,
    required this.onSeek,
    required this.onAddText,
    required this.onAddAudio,
    required this.onAddSticker,
    required this.onAddCaption,
    required this.onSelectClip,
    required this.onSelectText,
    required this.onSelectAudio,
    required this.onSplit,
    required this.onLongPressBlock,
  });

  final EditorState state;
  final List<Uint8List> thumbs;
  final bool thumbsLoading;
  final ValueChanged<int> onSeek;
  final VoidCallback onAddText;
  final VoidCallback onAddAudio;
  final VoidCallback onAddSticker;
  final VoidCallback onAddCaption;
  final ValueChanged<String> onSelectClip;
  final ValueChanged<String> onSelectText;
  final ValueChanged<String> onSelectAudio;
  final VoidCallback onSplit;
  final void Function(String kind, String id) onLongPressBlock;

  @override
  State<MultiTrackTimeline> createState() => _MultiTrackTimelineState();
}

class _MultiTrackTimelineState extends State<MultiTrackTimeline> {
  final ScrollController _hCtrl = ScrollController();
  final ScrollController _vCtrl = ScrollController();
  final ScrollController _hCtrlRuler = ScrollController();
  final ScrollController _vCtrlGutter = ScrollController();
  double _scaleStart = 0.06;

  // Drag state for tooltip + snap-line.
  int? _dragLabelMs;
  double? _dragLabelX;
  int? _snapLineMs;


  @override
  void initState() {
    super.initState();
    widget.state.positionNotifier.addListener(_followPlayhead);
    _hCtrl.addListener(_mirrorRuler);
    _vCtrl.addListener(_mirrorGutter);
  }

  @override
  void dispose() {
    widget.state.positionNotifier.removeListener(_followPlayhead);
    _hCtrl.removeListener(_mirrorRuler);
    _vCtrl.removeListener(_mirrorGutter);
    _hCtrl.dispose();
    _vCtrl.dispose();
    _hCtrlRuler.dispose();
    _vCtrlGutter.dispose();
    super.dispose();
  }

  void _mirrorRuler() {
    if (!_hCtrlRuler.hasClients) return;
    final target = _hCtrl.offset.clamp(
      _hCtrlRuler.position.minScrollExtent,
      _hCtrlRuler.position.maxScrollExtent,
    );
    if (_hCtrlRuler.offset != target) _hCtrlRuler.jumpTo(target);
  }

  void _mirrorGutter() {
    if (!_vCtrlGutter.hasClients) return;
    final target = _vCtrl.offset.clamp(
      _vCtrlGutter.position.minScrollExtent,
      _vCtrlGutter.position.maxScrollExtent,
    );
    if (_vCtrlGutter.offset != target) _vCtrlGutter.jumpTo(target);
  }

  void _followPlayhead() {
    if (!widget.state.isPlaying) return;
    if (!_hCtrl.hasClients) return;
    final pxPerMs = widget.state.timelinePxPerMs;
    final pos = widget.state.positionMs;
    final x = kSidePadding + pos * pxPerMs;
    final viewportW = _hCtrl.position.viewportDimension;
    final offset = _hCtrl.offset;
    // Keep playhead within central 30%..70% range during playback; otherwise
    // nudge. Manual scroll is left untouched so the user can browse freely.
    final localX = x - offset;
    if (localX > viewportW * 0.7) {
      final target =
          (x - viewportW * 0.5).clamp(0.0, _hCtrl.position.maxScrollExtent);
      _hCtrl.jumpTo(target);
    } else if (localX < viewportW * 0.15) {
      final target =
          (x - viewportW * 0.3).clamp(0.0, _hCtrl.position.maxScrollExtent);
      _hCtrl.jumpTo(target);
    }
  }


  void _onScaleStart(ScaleStartDetails d) {
    _scaleStart = widget.state.timelinePxPerMs;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.scale == 1.0) return;
    final next = (_scaleStart * d.scale).clamp(0.005, 2.0);
    if (next != widget.state.timelinePxPerMs) {
      widget.state.timelinePxPerMs = next;
      widget.state.notify();
    }
  }

  int _laneCount() {
    if (widget.state.texts.isEmpty) return 1;
    var maxLane = 0;
    for (final t in widget.state.texts) {
      if (t.lane > maxLane) maxLane = t.lane;
    }
    return maxLane + 1;
  }

  List<int> _snapTargets() {
    final ed = widget.state;
    final out = <int>{ed.positionMs, 0, ed.totalDurationMs};
    for (final c in ed.clips) {
      out.add(c.inMs);
      out.add(c.outMs);
    }
    for (final a in ed.audios) {
      final dur = a.outMs == 0x7fffffff ? ed.totalDurationMs : (a.outMs - a.inMs);
      out.add(a.startMs);
      out.add(a.startMs + dur);
    }
    for (final t in ed.texts) {
      out.add(t.startMs);
      out.add(t.endMs);
    }
    return out.toList()..sort();
  }

  /// Returns snapped ms (or original) and updates snap-line state.
  int snap(int desiredMs) {
    if (!widget.state.snapEnabled) {
      _snapLineMs = null;
      return desiredMs;
    }
    final pxPerMs = widget.state.timelinePxPerMs;
    if (pxPerMs <= 0) return desiredMs;
    final tolMs = (kSnapTolerancePx / pxPerMs).round();
    final targets = _snapTargets();
    var best = desiredMs;
    var bestDelta = tolMs + 1;
    for (final t in targets) {
      final d = (t - desiredMs).abs();
      if (d <= tolMs && d < bestDelta) {
        bestDelta = d;
        best = t;
      }
    }
    _snapLineMs = best == desiredMs ? null : best;
    return best;
  }

  void clearDragOverlay() {
    setState(() {
      _dragLabelMs = null;
      _dragLabelX = null;
      _snapLineMs = null;
    });
  }

  void updateDragOverlay(int ms, double xInContent) {
    setState(() {
      _dragLabelMs = ms;
      _dragLabelX = xInContent;
    });
  }

  void _fit(double availW) {
    final dur = widget.state.totalDurationMs;
    if (dur <= 0) return;
    final px = (availW - kGutterWidth - kSidePadding * 2) / dur;
    widget.state.timelinePxPerMs = px.clamp(0.005, 2.0);
    widget.state.notify();
  }

  void _zoomBy(double f) {
    final next = (widget.state.timelinePxPerMs * f).clamp(0.005, 2.0);
    widget.state.timelinePxPerMs = next;
    widget.state.notify();
  }

  List<Widget> _buildLaneContent(
    String kind, {
    required double pxPerMs,
    required double tracksW,
    required int laneCount,
    required double textBlockH,
  }) {
    final ed = widget.state;
    Widget body;
    switch (kind) {
      case 'text':
        body = SizedBox(
          height: textBlockH,
          width: tracksW,
          child: _TextLanes(
            state: ed,
            pxPerMs: pxPerMs,
            pad: kSidePadding,
            contentW: tracksW,
            laneCount: laneCount,
            host: this,
            onSelect: widget.onSelectText,
            onLongPress: (id) => widget.onLongPressBlock('text', id),
          ),
        );
        break;
      case 'audio':
        body = _AudioLane(
          state: ed,
          pxPerMs: pxPerMs,
          pad: kSidePadding,
          contentW: tracksW,
          host: this,
          onSelect: widget.onSelectAudio,
          onLongPress: (id) => widget.onLongPressBlock('audio', id),
        );
        break;
      case 'captions':
        body = _CaptionsLane(
          state: ed,
          pxPerMs: pxPerMs,
          pad: kSidePadding,
          contentW: tracksW,
          onSeek: widget.onSeek,
        );
        break;
      case 'stickers':
        body = _StickersLane(
          state: ed,
          pxPerMs: pxPerMs,
          pad: kSidePadding,
          contentW: tracksW,
          onSeek: widget.onSeek,
        );
        break;
      default:
        return const [];
    }
    return [RepaintBoundary(child: body), const SizedBox(height: kTrackGap)];
  }

  // Build the gutter chunk for a lane kind in laneOrder. Mirrors the heights
  // used by the content side so v-scroll stays aligned.
  List<Widget> _buildGutterForLane(
    String kind,
    int orderIdx,
    int laneCount,
    double textBlockH,
  ) {
    final ed = widget.state;
    Widget chunk;
    switch (kind) {
      case 'text':
        chunk = SizedBox(
          height: textBlockH,
          child: Column(
            children: [
              for (var i = 0; i < laneCount; i++) ...[
                _GutterLabel(
                  icon: ed.laneIsHidden(i)
                      ? Icons.visibility_off
                      : Icons.text_fields,
                  label: 'T${i + 1}',
                  dim: ed.laneIsHidden(i),
                  dragHandle: true,
                  onTap: () => _showLaneSheet('text', textLaneIdx: i),
                ),
                if (i != laneCount - 1) const SizedBox(height: kTrackGap),
              ],
            ],
          ),
        );
        break;
      case 'audio':
        chunk = _GutterLabel(
          icon: ed.audioHidden
              ? Icons.visibility_off
              : (ed.anyAudioMuted ? Icons.volume_off : Icons.music_note),
          label: 'A',
          dim: ed.audioHidden || ed.anyAudioMuted,
          dragHandle: true,
          onTap: () => _showLaneSheet('audio'),
        );
        break;
      case 'captions':
        chunk = _GutterLabel(
          icon: ed.captionsHidden
              ? Icons.visibility_off
              : Icons.closed_caption,
          label: 'CC',
          dim: ed.captionsHidden,
          dragHandle: true,
          onTap: () => _showLaneSheet('captions'),
        );
        break;
      case 'stickers':
        chunk = _GutterLabel(
          icon: ed.stickersHidden
              ? Icons.visibility_off
              : Icons.emoji_emotions,
          label: 'ST',
          dim: ed.stickersHidden,
          dragHandle: true,
          onTap: () => _showLaneSheet('stickers'),
        );
        break;
      default:
        chunk = const SizedBox.shrink();
    }
    final draggable = LongPressDraggable<int>(
      data: orderIdx,
      delay: const Duration(milliseconds: 280),
      onDragStarted: () => HapticFeedback.mediumImpact(),
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: kGutterWidth - 4,
          child: Opacity(opacity: 0.85, child: chunk),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: chunk),
      axis: Axis.vertical,
      child: chunk,
    );
    final target = DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != orderIdx,
      onAcceptWithDetails: (d) {
        ed.reorderLanes(d.data, orderIdx);
        HapticFeedback.lightImpact();
      },
      builder: (_, candidate, __) {
        final hovering = candidate.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          decoration: hovering
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border:
                      Border.all(color: const Color(0xFFFBBF24), width: 1.5),
                )
              : null,
          child: draggable,
        );
      },
    );
    return [target, const SizedBox(height: kTrackGap)];
  }

  /// Bottom sheet for a lane header. `kind` ∈ {video, text, audio, captions,
  /// stickers}. `textLaneIdx` only used for text lanes.
  void _showLaneSheet(String kind, {int? textLaneIdx}) {
    final ed = widget.state;
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kBgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (sheetCtx) {
        bool isHidden() {
          switch (kind) {
            case 'video':
              return ed.videoHidden;
            case 'text':
              return textLaneIdx != null && ed.laneIsHidden(textLaneIdx);
            case 'audio':
              return ed.audioHidden;
            case 'captions':
              return ed.captionsHidden;
            case 'stickers':
              return ed.stickersHidden;
          }
          return false;
        }

        void toggleHide() {
          switch (kind) {
            case 'video':
              ed.setVideoHidden(!ed.videoHidden);
              break;
            case 'text':
              if (textLaneIdx != null) ed.toggleLaneVisibility(textLaneIdx);
              break;
            case 'audio':
              ed.setAudioHidden(!ed.audioHidden);
              break;
            case 'captions':
              ed.setCaptionsHidden(!ed.captionsHidden);
              break;
            case 'stickers':
              ed.setStickersHidden(!ed.stickersHidden);
              break;
          }
        }

        final showMute = kind == 'video' || kind == 'audio';
        bool muted() => kind == 'video' ? ed.clipMuted : ed.anyAudioMuted;
        void toggleMute() {
          if (kind == 'video') {
            ed.clipMuted = !ed.clipMuted;
            ed.notify();
          } else {
            ed.muteAllAudio(!ed.anyAudioMuted);
          }
        }

        String title() {
          switch (kind) {
            case 'video':
              return 'Video lane';
            case 'text':
              return 'Text lane ${(textLaneIdx ?? 0) + 1}';
            case 'audio':
              return 'Audio lane';
            case 'captions':
              return 'Captions lane';
            case 'stickers':
              return 'Stickers lane';
          }
          return 'Lane';
        }

        return StatefulBuilder(
          builder: (_, setSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Text(
                            title(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      leading: Icon(
                        isHidden() ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white70,
                      ),
                      title: Text(
                        isHidden() ? 'Unhide track' : 'Hide track',
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        'Toggles preview-window visibility for this track.',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      onTap: () {
                        toggleHide();
                        setSheet(() {});
                      },
                    ),
                    if (showMute)
                      ListTile(
                        leading: Icon(
                          muted() ? Icons.volume_off : Icons.volume_up,
                          color: Colors.white70,
                        ),
                        title: Text(
                          muted() ? 'Unmute audio' : 'Mute audio',
                          style: const TextStyle(color: Colors.white),
                        ),
                        onTap: () {
                          toggleMute();
                          setSheet(() {});
                        },
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Approximate visible ms range based on hCtrl + viewport.
  (int, int) visibleRange() {
    if (!_hCtrl.hasClients) return (0, widget.state.totalDurationMs);
    final pxPerMs = widget.state.timelinePxPerMs;
    if (pxPerMs <= 0) return (0, widget.state.totalDurationMs);
    final offset = _hCtrl.offset;
    final viewportW = _hCtrl.position.viewportDimension;
    final startMs = ((offset - kSidePadding) / pxPerMs)
        .floor()
        .clamp(0, widget.state.totalDurationMs);
    final endMs = ((offset + viewportW - kSidePadding) / pxPerMs)
        .ceil()
        .clamp(0, widget.state.totalDurationMs);
    // Add ±300px culling slack so dragging is smooth.
    final slack = (300 / pxPerMs).ceil();
    return ((startMs - slack).clamp(0, widget.state.totalDurationMs),
        (endMs + slack).clamp(0, widget.state.totalDurationMs));
  }

  @override
  Widget build(BuildContext context) {
    final ed = widget.state;
    final pxPerMs = ed.timelinePxPerMs;
    final dur = ed.totalDurationMs.clamp(1, 1 << 30);
    final laneCount = _laneCount();
    final textBlockH = laneCount * (kTrackHeight + kTrackGap);

    final tracksW = dur * pxPerMs + kSidePadding * 2;

    return LayoutBuilder(
      builder: (_, outer) {
        return Container(
          color: kBgBlack,
          child: Column(
            children: [
              // Top toolbar: zoom + split + position.
              _Toolbar(
                state: ed,
                onZoomIn: () => _zoomBy(1.5),
                onZoomOut: () => _zoomBy(1 / 1.5),
                onFit: () => _fit(outer.maxWidth),
                onSplit: widget.onSplit,
              ),
              // Ruler row: gutter (empty) + scrollable ruler.
              SizedBox(
                height: kRulerHeight + 4,
                child: Row(
                  children: [
                    const SizedBox(width: kGutterWidth),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _hCtrlRuler,
                        scrollDirection: Axis.horizontal,
                        physics: const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: tracksW,
                          height: kRulerHeight,
                          child: CustomPaint(
                            painter: _RulerPainter(
                              durationMs: dur,
                              pxPerMs: pxPerMs,
                              pad: kSidePadding,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    // Left gutter — sticky track-type headers. Tap → bottom
                    // sheet (hide/mute). Long-press + drag → reorder lanes.
                    SizedBox(
                      width: kGutterWidth,
                      child: SingleChildScrollView(
                        controller: _vCtrlGutter,
                        scrollDirection: Axis.vertical,
                        physics: const NeverScrollableScrollPhysics(),
                        child: Column(
                          children: [
                            const SizedBox(height: 4),
                            _GutterLabel(
                              icon: ed.videoHidden
                                  ? Icons.visibility_off
                                  : (ed.clipMuted
                                      ? Icons.volume_off
                                      : Icons.movie_outlined),
                              label: 'V',
                              dim: ed.videoHidden || ed.clipMuted,
                              onTap: () => _showLaneSheet('video'),
                            ),
                            const SizedBox(height: kTrackGap),
                            for (var oi = 0; oi < ed.laneOrder.length; oi++)
                              ..._buildGutterForLane(
                                ed.laneOrder[oi],
                                oi,
                                laneCount,
                                textBlockH,
                              ),
                            // padding placeholder for chip row
                            const SizedBox(height: 36),
                          ],
                        ),
                      ),
                    ),
                    // Scrollable tracks.
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        child: Stack(
                          children: [
                            SingleChildScrollView(
                              controller: _vCtrl,
                              scrollDirection: Axis.vertical,
                              physics: const ClampingScrollPhysics(),
                              child: SingleChildScrollView(
                                controller: _hCtrl,
                                scrollDirection: Axis.horizontal,
                                physics: const ClampingScrollPhysics(),
                                child: SizedBox(
                                  width: tracksW,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 4),
                                      RepaintBoundary(
                                        child: _VideoStrip(
                                          state: ed,
                                          thumbs: widget.thumbs,
                                          pxPerMs: pxPerMs,
                                          pad: kSidePadding,
                                          contentW: tracksW,
                                          onSelectClip: widget.onSelectClip,
                                          onLongPress: (id) =>
                                              widget.onLongPressBlock('clip', id),
                                          onSeek: widget.onSeek,
                                        ),
                                      ),
                                      const SizedBox(height: kTrackGap),
                                      for (final kind in ed.laneOrder)
                                        ..._buildLaneContent(
                                          kind,
                                          pxPerMs: pxPerMs,
                                          tracksW: tracksW,
                                          laneCount: laneCount,
                                          textBlockH: textBlockH,
                                        ),
                                      SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: kSidePadding,
                                            vertical: 4),
                                        physics:
                                            const ClampingScrollPhysics(),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            _AddTrackChip(
                                              icon: Icons.text_fields,
                                              label: '+ Text lane',
                                              onTap: widget.onAddText,
                                            ),
                                            const SizedBox(width: 8),
                                            _AddTrackChip(
                                              icon: Icons.music_note,
                                              label: '+ Audio',
                                              onTap: widget.onAddAudio,
                                            ),
                                            const SizedBox(width: 8),
                                            _AddTrackChip(
                                              icon: Icons.emoji_emotions,
                                              label: '+ Sticker',
                                              onTap: widget.onAddSticker,
                                            ),
                                            const SizedBox(width: 8),
                                            _AddTrackChip(
                                              icon: Icons.closed_caption,
                                              label: '+ Caption',
                                              onTap: widget.onAddCaption,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            // Track-wide gridlines.
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _GridlinesPainter(
                                    durationMs: dur,
                                    pxPerMs: pxPerMs,
                                    pad: kSidePadding,
                                  ),
                                ),
                              ),
                            ),
                            // Long-press scrub overlay + tap-to-clear-selection.
                            Positioned.fill(
                              child: _SeekOverlay(
                                state: ed,
                                hCtrl: _hCtrl,
                                pxPerMs: pxPerMs,
                                pad: kSidePadding,
                                onSeek: widget.onSeek,
                              ),
                            ),
                            // Snap guideline.
                            if (_snapLineMs != null)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: _SnapLine(
                                    hCtrl: _hCtrl,
                                    ms: _snapLineMs!,
                                    pxPerMs: pxPerMs,
                                    pad: kSidePadding,
                                  ),
                                ),
                              ),
                            // Playhead.
                            Positioned.fill(
                              child: IgnorePointer(
                                child: _Playhead(
                                  state: ed,
                                  hCtrl: _hCtrl,
                                  pxPerMs: pxPerMs,
                                  pad: kSidePadding,
                                ),
                              ),
                            ),
                            // Drag tooltip.
                            if (_dragLabelMs != null && _dragLabelX != null)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: _DragTooltip(
                                    hCtrl: _hCtrl,
                                    xInContent: _dragLabelX!,
                                    ms: _dragLabelMs!,
                                  ),
                                ),
                              ),
                            if (widget.thumbs.isEmpty && widget.thumbsLoading)
                              const Positioned(
                                top: 12,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white38,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.state,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onSplit,
  });
  final EditorState state;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onSplit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: kBgBlack,
      child: Row(
        children: [
          _PositionLabel(state: state),
          const SizedBox(width: 8),
          _ProxyChip(state: state),
          const Spacer(),
          _TbButton(icon: Icons.content_cut, tip: 'Split (S)', onTap: onSplit),
          const SizedBox(width: 6),
          _TbButton(icon: Icons.zoom_out_map, tip: 'Fit', onTap: onFit),
          _TbButton(icon: Icons.remove, tip: 'Zoom out', onTap: onZoomOut),
          _TbButton(icon: Icons.add, tip: 'Zoom in', onTap: onZoomIn),
        ],
      ),
    );
  }
}

class _ProxyChip extends StatelessWidget {
  const _ProxyChip({required this.state});
  final EditorState state;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        state.proxyMode = !state.proxyMode;
        state.notify();
      },
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: state.proxyMode ? kAccentCyan : Colors.transparent,
          border: Border.all(
            color: state.proxyMode ? kAccentCyan : Colors.white38,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          state.proxyMode ? 'PROXY' : 'FULL',
          style: TextStyle(
            color: state.proxyMode ? Colors.black : Colors.white70,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _TbButton extends StatelessWidget {
  const _TbButton({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Icon(icon, color: Colors.white, size: 16),
        ),
      ),
    );
  }
}

class _GutterLabel extends StatelessWidget {
  const _GutterLabel({
    required this.icon,
    required this.label,
    this.dim = false,
    this.onTap,
    this.dragHandle = false,
  });
  final IconData icon;
  final String label;
  final bool dim;
  final VoidCallback? onTap;
  final bool dragHandle;
  @override
  Widget build(BuildContext context) {
    final tint = dim ? Colors.white30 : Colors.white70;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: kTrackHeight,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: kBgSurface,
          borderRadius: BorderRadius.circular(3),
          border: dim
              ? Border.all(color: Colors.redAccent.withValues(alpha: 0.5))
              : null,
        ),
        child: Stack(
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 12, color: tint),
                const SizedBox(height: 1),
                Text(
                  label,
                  style: TextStyle(
                    color: tint,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (dragHandle)
              Positioned(
                right: 1,
                top: 2,
                child: Icon(
                  Icons.drag_indicator,
                  size: 9,
                  color: Colors.white24,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PositionLabel extends StatefulWidget {
  const _PositionLabel({required this.state});
  final EditorState state;
  @override
  State<_PositionLabel> createState() => _PositionLabelState();
}

class _PositionLabelState extends State<_PositionLabel> {

  String _fmt(int ms) {
    final s = (ms ~/ 1000).clamp(0, 359999);
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    final fff = (ms % 1000).toString().padLeft(3, '0');
    return '$mm:$ss.$fff';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () {
        widget.state.showFps = !widget.state.showFps;
        widget.state.notify();
        HapticFeedback.mediumImpact();
      },
      child: ValueListenableBuilder<int>(
        valueListenable: widget.state.positionNotifier,
        builder: (_, pos, __) {
          return Text(
            '${_fmt(pos)} / ${_fmt(widget.state.totalDurationMs)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          );
        },
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.durationMs,
    required this.pxPerMs,
    required this.pad,
  });
  final int durationMs;
  final double pxPerMs;
  final double pad;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    final majorPaint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    var stepMs = 1000;
    const candidates = [
      200, 500, 1000, 2000, 5000, 10000, 30000, 60000, 120000, 300000
    ];
    for (final c in candidates) {
      if (c * pxPerMs >= 80) {
        stepMs = c;
        break;
      }
    }
    for (var t = 0; t <= durationMs; t += stepMs) {
      final x = pad + t * pxPerMs;
      final isMajor = (t % (stepMs * 5) == 0);
      canvas.drawLine(
        Offset(x, size.height - (isMajor ? 12 : 6)),
        Offset(x, size.height),
        isMajor ? majorPaint : paint,
      );
      if (isMajor) {
        final sec = t ~/ 1000;
        tp.text = TextSpan(
          text: '${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}',
          style: const TextStyle(color: Colors.white54, fontSize: 9),
        );
        tp.layout();
        tp.paint(canvas, Offset(x + 2, 0));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.durationMs != durationMs || old.pxPerMs != pxPerMs || old.pad != pad;
}

class _VideoStrip extends StatelessWidget {
  const _VideoStrip({
    required this.state,
    required this.thumbs,
    required this.pxPerMs,
    required this.pad,
    required this.contentW,
    required this.onSelectClip,
    required this.onLongPress,
    required this.onSeek,
  });
  final EditorState state;
  final List<Uint8List> thumbs;
  final double pxPerMs;
  final double pad;
  final double contentW;
  final ValueChanged<String> onSelectClip;
  final ValueChanged<String> onLongPress;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) {
    final clips = state.clips;
    if (clips.isEmpty) {
      return SizedBox(
        width: contentW,
        height: kTrackHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSidePadding),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: Colors.white24,
                width: 1,
                style: BorderStyle.solid,
              ),
            ),
            child: const Center(
              child: Text(
                'No clips · Tap + below to add',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          ),
        ),
      );
    }
    return ValueListenableBuilder<EditorSelection>(
      valueListenable: state.selectionNotifier,
      builder: (_, sel, __) {
        return SizedBox(
          width: contentW,
          height: kTrackHeight,
          child: Stack(
            children: [
              for (var ci = 0; ci < clips.length; ci++)
                _ClipBlock(
                  state: state,
                  clipIndex: ci,
                  thumbs: _thumbsForClip(ci),
                  pxPerMs: pxPerMs,
                  left: pad + clips[ci].inMs * pxPerMs,
                  width: (clips[ci].outMs - clips[ci].inMs) * pxPerMs,
                  selected: sel.clipId == clips[ci].id,
                  onTap: () => onSelectClip(clips[ci].id),
                  onLongPress: () => onLongPress(clips[ci].id),
                ),
            ],
          ),
        );
      },
    );
  }

  // Map each clip's time range to the matching slice of the global thumb
  // strip so trims / reorders never desync image content from playhead time.
  List<Uint8List> _thumbsForClip(int ci) {
    if (thumbs.isEmpty) return const [];
    final total = state.totalDurationMs;
    if (total <= 0) return thumbs;
    final c = state.clips[ci];
    final n = thumbs.length;
    final startIdx = (c.inMs / total * n).floor().clamp(0, n - 1);
    final endIdx = (c.outMs / total * n).ceil().clamp(startIdx + 1, n);
    return thumbs.sublist(startIdx, endIdx);
  }
}

class _ClipBlock extends StatelessWidget {
  const _ClipBlock({
    required this.state,
    required this.clipIndex,
    required this.thumbs,
    required this.pxPerMs,
    required this.left,
    required this.width,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });
  final EditorState state;
  final int clipIndex;
  final List<Uint8List> thumbs;
  final double pxPerMs;
  final double left;
  final double width;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  void _resizeLeft(double dxPx) {
    final dMs = (dxPx / pxPerMs).round();
    final c = state.clips[clipIndex];
    final maxIn = c.outMs - 100;
    final neighbor = clipIndex > 0 ? state.clips[clipIndex - 1].outMs : 0;
    final newIn = (c.inMs + dMs).clamp(neighbor, maxIn);
    // Ripple-shift left edge: maintain duration by shifting outMs as well?
    // No — trimming means duration drops, later clips slide left by the same.
    final delta = newIn - c.inMs;
    c.inMs = newIn;
    for (var i = clipIndex + 1; i < state.clips.length; i++) {
      state.clips[i].inMs =
          (state.clips[i].inMs - delta).clamp(0, state.totalDurationMs);
      state.clips[i].outMs =
          (state.clips[i].outMs - delta).clamp(0, state.totalDurationMs);
    }
    state.notify();
  }

  void _resizeRight(double dxPx) {
    final dMs = (dxPx / pxPerMs).round();
    final c = state.clips[clipIndex];
    final minOut = c.inMs + 100;
    final newOut =
        (c.outMs + dMs).clamp(minOut, state.totalDurationMs);
    final delta = newOut - c.outMs;
    c.outMs = newOut;
    for (var i = clipIndex + 1; i < state.clips.length; i++) {
      state.clips[i].inMs =
          (state.clips[i].inMs + delta).clamp(0, state.totalDurationMs);
      state.clips[i].outMs =
          (state.clips[i].outMs + delta).clamp(0, state.totalDurationMs);
    }
    state.notify();
  }

  @override
  Widget build(BuildContext context) {
    final w = width.clamp(8.0, double.infinity);
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: w,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _clipBody(hoverBorder: false),
            if (selected) ..._trimHandles(),
          ],
        ),
      ),
    );
  }

  List<Widget> _trimHandles() => [
        Positioned(
          left: -3,
          top: 0,
          bottom: 0,
          width: 10,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => _resizeLeft(d.delta.dx),
            onHorizontalDragEnd: (_) => HapticFeedback.lightImpact(),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              color: Colors.white,
            ),
          ),
        ),
        Positioned(
          right: -3,
          top: 0,
          bottom: 0,
          width: 10,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => _resizeRight(d.delta.dx),
            onHorizontalDragEnd: (_) => HapticFeedback.lightImpact(),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 6),
              color: Colors.white,
            ),
          ),
        ),
      ];

  Widget _clipBody({required bool hoverBorder}) {
    return Container(
            decoration: BoxDecoration(
              color: kBgSurface,
              border: Border.all(
                color: hoverBorder
                    ? const Color(0xFFFBBF24)
                    : (selected ? Colors.white : Colors.white12),
                width: hoverBorder ? 2 : (selected ? 2 : 0.5),
              ),
              borderRadius: BorderRadius.circular(3),
            ),
            clipBehavior: Clip.antiAlias,
            child: thumbs.isEmpty
                  ? const SizedBox.expand()
                  : Stack(
                      children: [
                        RepaintBoundary(
                          child: LayoutBuilder(
                            builder: (_, bc) {
                              // Fixed-square cells (≈kTrackHeight wide) so
                              // zooming in lays MORE cells instead of stretching
                              // existing ones — eliminates the "repeating frame"
                              // visual when pxPerMs grows.
                              const cellW = kTrackHeight;
                              final cellCount =
                                  (bc.maxWidth / cellW).ceil().clamp(1, 256);
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.start,
                                children: [
                                  for (var i = 0; i < cellCount; i++)
                                    SizedBox(
                                      width: cellW,
                                      height: bc.maxHeight,
                                      child: Image.memory(
                                        thumbs[
                                            (i * thumbs.length / cellCount)
                                                .floor()
                                                .clamp(0, thumbs.length - 1)],
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                        filterQuality: FilterQuality.low,
                                        cacheWidth: 96,
                                        cacheHeight: 96,
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                        if (state.clips[clipIndex].speed != 1.0 ||
                            state.clips[clipIndex].muted)
                          Positioned(
                            left: 3,
                            top: 3,
                            child: Row(
                              children: [
                                if (state.clips[clipIndex].speed != 1.0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                    child: Text(
                                      '${state.clips[clipIndex].speed.toStringAsFixed(state.clips[clipIndex].speed == state.clips[clipIndex].speed.roundToDouble() ? 0 : 1)}x',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                if (state.clips[clipIndex].muted)
                                  Container(
                                    margin: const EdgeInsets.only(left: 3),
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                    child: const Icon(Icons.volume_off,
                                        color: Colors.white, size: 10),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
          );
  }
}

class _TextLanes extends StatelessWidget {
  const _TextLanes({
    required this.state,
    required this.pxPerMs,
    required this.pad,
    required this.contentW,
    required this.laneCount,
    required this.host,
    required this.onSelect,
    required this.onLongPress,
  });
  final EditorState state;
  final double pxPerMs;
  final double pad;
  final double contentW;
  final int laneCount;
  final _MultiTrackTimelineState host;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onLongPress;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EditorSelection>(
      valueListenable: state.selectionNotifier,
      builder: (_, sel, __) {
        return Stack(
          children: [
            for (var l = 0; l < laneCount; l++)
              Positioned(
                left: pad,
                right: pad,
                top: l * (kTrackHeight + kTrackGap),
                height: kTrackHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            for (final t in state.texts)
              if (_inViewport(t.startMs, t.endMs, host.visibleRange()))
                _TextBlock(
                  key: ValueKey('text-${t.id}'),
                  state: state,
                  overlay: t,
                  pxPerMs: pxPerMs,
                  pad: pad,
                  host: host,
                  selected: sel.overlayId == t.id,
                  onTap: () => onSelect(t.id),
                  onLongPress: () => onLongPress(t.id),
                ),
          ],
        );
      },
    );
  }
}

class _TextBlock extends StatefulWidget {
  const _TextBlock({
    super.key,
    required this.state,
    required this.overlay,
    required this.pxPerMs,
    required this.pad,
    required this.host,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });
  final EditorState state;
  final TextOverlay overlay;
  final double pxPerMs;
  final double pad;
  final _MultiTrackTimelineState host;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_TextBlock> createState() => _TextBlockState();
}

class _TextBlockState extends State<_TextBlock> {
  double _dragDx = 0;
  double _dragDy = 0;

  @override
  Widget build(BuildContext context) {
    final t = widget.overlay;
    final left = widget.pad + t.startMs * widget.pxPerMs + _dragDx;
    final width = ((t.endMs - t.startMs) * widget.pxPerMs).clamp(20.0, 1e6);
    final top = t.lane * (kTrackHeight + kTrackGap) + _dragDy;

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: kTrackHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onPanUpdate: (d) {
          setState(() {
            _dragDx += d.delta.dx;
            _dragDy += d.delta.dy;
          });
          final dMs = (_dragDx / widget.pxPerMs).round();
          final desired = (t.startMs + dMs).clamp(0, widget.state.totalDurationMs);
          final snapped = widget.host.snap(desired);
          widget.host.updateDragOverlay(snapped, widget.pad + snapped * widget.pxPerMs);
          // Scrub preview during drag.
          widget.state.positionMs = snapped;
        },
        onPanEnd: (_) {
          final dMs = (_dragDx / widget.pxPerMs).round();
          final desired = (t.startMs + dMs).clamp(0, widget.state.totalDurationMs);
          final newStart = widget.host.snap(desired);
          final dur = t.endMs - t.startMs;
          t.startMs = newStart;
          t.endMs = (newStart + dur).clamp(0, widget.state.totalDurationMs);

          final laneDelta = (_dragDy / (kTrackHeight + kTrackGap)).round();
          final newLane = (t.lane + laneDelta).clamp(0, 31);
          t.lane = newLane;

          setState(() {
            _dragDx = 0;
            _dragDy = 0;
          });
          widget.host.clearDragOverlay();
          HapticFeedback.selectionClick();
          widget.state.notify();
        },
        child: Container(
          decoration: BoxDecoration(
            color: kAccentCyan.withValues(alpha: widget.selected ? 0.85 : 0.5),
            border: Border.all(
              color: widget.selected ? Colors.white : Colors.transparent,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(3),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.centerLeft,
          child: Text(
            t.text.isEmpty ? 'Text' : t.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
          ),
          if (widget.selected) ...[
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  final dMs = (d.delta.dx / widget.pxPerMs).round();
                  final newStart = (t.startMs + dMs)
                      .clamp(0, t.endMs - 100);
                  t.startMs = newStart;
                  widget.state.notify();
                },
                child: Container(color: Colors.white),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  final dMs = (d.delta.dx / widget.pxPerMs).round();
                  final newEnd = (t.endMs + dMs)
                      .clamp(t.startMs + 100, widget.state.totalDurationMs);
                  t.endMs = newEnd;
                  widget.state.notify();
                },
                child: Container(color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AudioLane extends StatelessWidget {
  const _AudioLane({
    required this.state,
    required this.pxPerMs,
    required this.pad,
    required this.contentW,
    required this.host,
    required this.onSelect,
    required this.onLongPress,
  });
  final EditorState state;
  final double pxPerMs;
  final double pad;
  final double contentW;
  final _MultiTrackTimelineState host;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onLongPress;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EditorSelection>(
      valueListenable: state.selectionNotifier,
      builder: (_, sel, __) {
        return SizedBox(
          width: contentW,
          height: kTrackHeight,
          child: Stack(
            children: [
              Positioned(
                left: pad,
                right: pad,
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              for (final a in state.audios)
                if (_inViewport(
                    a.startMs,
                    a.outMs == 0x7fffffff
                        ? state.totalDurationMs
                        : a.startMs + (a.outMs - a.inMs),
                    host.visibleRange()))
                  _AudioBlock(
                    state: state,
                    audio: a,
                    pxPerMs: pxPerMs,
                    pad: pad,
                    host: host,
                    selected: sel.overlayId == a.id,
                    onTap: () => onSelect(a.id),
                    onLongPress: () => onLongPress(a.id),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _AudioBlock extends StatefulWidget {
  const _AudioBlock({
    required this.state,
    required this.audio,
    required this.pxPerMs,
    required this.pad,
    required this.host,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });
  final EditorState state;
  final AudioTrack audio;
  final double pxPerMs;
  final double pad;
  final _MultiTrackTimelineState host;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_AudioBlock> createState() => _AudioBlockState();
}

class _AudioBlockState extends State<_AudioBlock> {
  double _dragDx = 0;

  int _durMs() {
    final a = widget.audio;
    if (a.outMs == 0x7fffffff) return widget.state.totalDurationMs;
    return (a.outMs - a.inMs).clamp(0, 1 << 30);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.audio;
    final left = widget.pad + a.startMs * widget.pxPerMs + _dragDx;
    final width = (_durMs() * widget.pxPerMs).clamp(20.0, 1e6);

    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: width,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onHorizontalDragUpdate: (d) {
          setState(() => _dragDx += d.delta.dx);
          final dMs = (_dragDx / widget.pxPerMs).round();
          final desired = (a.startMs + dMs).clamp(0, widget.state.totalDurationMs);
          final snapped = widget.host.snap(desired);
          widget.host.updateDragOverlay(snapped, widget.pad + snapped * widget.pxPerMs);
        },
        onHorizontalDragEnd: (_) {
          final dMs = (_dragDx / widget.pxPerMs).round();
          final desired = (a.startMs + dMs).clamp(0, widget.state.totalDurationMs);
          a.startMs = widget.host.snap(desired);
          setState(() => _dragDx = 0);
          widget.host.clearDragOverlay();
          HapticFeedback.selectionClick();
          widget.state.notify();
        },
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E3A2F),
            border: Border.all(
              color: widget.selected
                  ? Colors.white
                  : Colors.greenAccent.withValues(alpha: 0.5),
              width: widget.selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(3),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              AudioWaveform(
                path: a.path,
                width: width,
                height: kTrackHeight,
                color: Colors.greenAccent,
                muted: a.muted || a.volume == 0,
              ),
              // Fade-in ramp visualization (left wedge).
              if (a.fadeInMs > 0)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: (a.fadeInMs * widget.pxPerMs).clamp(0.0, width),
                  child: const _FadeWedge(rightTop: true),
                ),
              if (a.fadeOutMs > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: (a.fadeOutMs * widget.pxPerMs).clamp(0.0, width),
                  child: const _FadeWedge(rightTop: false),
                ),
              if (widget.selected) ...[
                _FadeHandle(
                  side: _FadeSide.start,
                  audio: a,
                  pxPerMs: widget.pxPerMs,
                  blockWidth: width,
                  onChanged: () => widget.state.notify(),
                ),
                _FadeHandle(
                  side: _FadeSide.end,
                  audio: a,
                  pxPerMs: widget.pxPerMs,
                  blockWidth: width,
                  onChanged: () => widget.state.notify(),
                ),
              ],
              if (a.muted)
                Positioned(
                  left: 4,
                  top: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: const Icon(Icons.volume_off,
                        color: Colors.white, size: 10),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridlinesPainter extends CustomPainter {
  _GridlinesPainter({
    required this.durationMs,
    required this.pxPerMs,
    required this.pad,
  });
  final int durationMs;
  final double pxPerMs;
  final double pad;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 0.5;
    var stepMs = 1000;
    const candidates = [
      200, 500, 1000, 2000, 5000, 10000, 30000, 60000, 120000, 300000
    ];
    for (final c in candidates) {
      if (c * pxPerMs >= 80) {
        stepMs = c;
        break;
      }
    }
    final majorStep = stepMs * 5;
    for (var t = 0; t <= durationMs; t += majorStep) {
      final x = pad + t * pxPerMs;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridlinesPainter old) =>
      old.durationMs != durationMs ||
      old.pxPerMs != pxPerMs ||
      old.pad != pad;
}

class _SeekOverlay extends StatelessWidget {
  const _SeekOverlay({
    required this.state,
    required this.hCtrl,
    required this.pxPerMs,
    required this.pad,
    required this.onSeek,
  });
  final EditorState state;
  final ScrollController hCtrl;
  final double pxPerMs;
  final double pad;
  final ValueChanged<int> onSeek;

  void _seekAt(double localDx) {
    final scroll = hCtrl.hasClients ? hCtrl.offset : 0.0;
    final x = localDx + scroll - pad;
    if (x < 0 || pxPerMs <= 0) return;
    final ms = (x / pxPerMs).round().clamp(0, state.totalDurationMs);
    onSeek(ms);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (state.selectedOverlayId != null) state.selectedOverlayId = null;
        if (state.selectedClipId != null) state.selectedClipId = null;
      },
      onLongPressStart: (d) => _seekAt(d.localPosition.dx),
      onLongPressMoveUpdate: (d) => _seekAt(d.localPosition.dx),
    );
  }
}

class _Playhead extends StatelessWidget {
  const _Playhead({
    required this.state,
    required this.hCtrl,
    required this.pxPerMs,
    required this.pad,
  });
  final EditorState state;
  final ScrollController hCtrl;
  final double pxPerMs;
  final double pad;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: state.positionNotifier,
      builder: (_, pos, __) {
        final scroll = hCtrl.hasClients ? hCtrl.offset : 0.0;
        final x = pad + pos * pxPerMs - scroll;
        return Stack(
          children: [
            Positioned(
              left: x.clamp(0.0, 1e6),
              top: 0,
              bottom: 0,
              width: 2,
              child: Container(color: kAccentCyan),
            ),
            Positioned(
              left: (x - 5).clamp(0.0, 1e6),
              top: 0,
              width: 12,
              height: 6,
              child: Container(
                decoration: const BoxDecoration(
                  color: kAccentCyan,
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(2),
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SnapLine extends StatelessWidget {
  const _SnapLine({
    required this.hCtrl,
    required this.ms,
    required this.pxPerMs,
    required this.pad,
  });
  final ScrollController hCtrl;
  final int ms;
  final double pxPerMs;
  final double pad;

  @override
  Widget build(BuildContext context) {
    final scroll = hCtrl.hasClients ? hCtrl.offset : 0.0;
    final x = pad + ms * pxPerMs - scroll;
    return Stack(
      children: [
        Positioned(
          left: x.clamp(0.0, 1e6),
          top: 0,
          bottom: 0,
          width: 1,
          child: const ColoredBox(color: Colors.yellow),
        ),
      ],
    );
  }
}

class _DragTooltip extends StatelessWidget {
  const _DragTooltip({
    required this.hCtrl,
    required this.xInContent,
    required this.ms,
  });
  final ScrollController hCtrl;
  final double xInContent;
  final int ms;

  String _fmt(int ms) {
    final s = (ms ~/ 1000).clamp(0, 359999);
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    final fff = (ms % 1000).toString().padLeft(3, '0');
    return '$mm:$ss.$fff';
  }

  @override
  Widget build(BuildContext context) {
    final scroll = hCtrl.hasClients ? hCtrl.offset : 0.0;
    final x = xInContent - scroll - 24;
    return Stack(
      children: [
        Positioned(
          left: x.clamp(0.0, 1e6),
          top: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.8),
              border: Border.all(color: kAccentCyan, width: 1),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              _fmt(ms),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddTrackChip extends StatelessWidget {
  const _AddTrackChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: kBgSurface,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

enum _FadeSide { start, end }

class _FadeHandle extends StatelessWidget {
  const _FadeHandle({
    required this.side,
    required this.audio,
    required this.pxPerMs,
    required this.blockWidth,
    required this.onChanged,
  });
  final _FadeSide side;
  final AudioTrack audio;
  final double pxPerMs;
  final double blockWidth;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final isStart = side == _FadeSide.start;
    final fadeMs = isStart ? audio.fadeInMs : audio.fadeOutMs;
    final offset = (fadeMs * pxPerMs).clamp(0.0, blockWidth);
    return Positioned(
      left: isStart ? offset : null,
      right: isStart ? null : offset,
      top: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) {
          final dxMs = (d.delta.dx / pxPerMs).round();
          if (isStart) {
            audio.fadeInMs = (audio.fadeInMs + dxMs).clamp(0, 5000);
          } else {
            audio.fadeOutMs = (audio.fadeOutMs - dxMs).clamp(0, 5000);
          }
          onChanged();
        },
        child: Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: Colors.yellow,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

class _FadeWedge extends StatelessWidget {
  const _FadeWedge({required this.rightTop});
  final bool rightTop;
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _FadeWedgePainter(rightTop: rightTop));
  }
}

class _FadeWedgePainter extends CustomPainter {
  _FadeWedgePainter({required this.rightTop});
  final bool rightTop;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.black.withValues(alpha: 0.4);
    final path = Path();
    if (rightTop) {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(0, size.height);
      path.close();
    } else {
      path.moveTo(size.width, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
      path.close();
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _FadeWedgePainter old) =>
      old.rightTop != rightTop;
}

class _CaptionsLane extends StatelessWidget {
  const _CaptionsLane({
    required this.state,
    required this.pxPerMs,
    required this.pad,
    required this.contentW,
    required this.onSeek,
  });
  final EditorState state;
  final double pxPerMs;
  final double pad;
  final double contentW;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EditorSelection>(
      valueListenable: state.selectionNotifier,
      builder: (_, sel, __) {
        return SizedBox(
          width: contentW,
          height: kTrackHeight,
          child: Stack(
            children: [
              Positioned(
                left: pad,
                right: pad,
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              for (final cap in state.captions)
                _CaptionBlock(
                  key: ValueKey('cap-${cap.id}'),
                  state: state,
                  caption: cap,
                  pxPerMs: pxPerMs,
                  pad: pad,
                  selected: sel.overlayId == cap.id,
                  onSeek: onSeek,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CaptionBlock extends StatefulWidget {
  const _CaptionBlock({
    super.key,
    required this.state,
    required this.caption,
    required this.pxPerMs,
    required this.pad,
    required this.selected,
    required this.onSeek,
  });
  final EditorState state;
  final Caption caption;
  final double pxPerMs;
  final double pad;
  final bool selected;
  final ValueChanged<int> onSeek;

  @override
  State<_CaptionBlock> createState() => _CaptionBlockState();
}

class _CaptionBlockState extends State<_CaptionBlock> {
  double _dragDx = 0;

  Future<void> _editCaption(BuildContext context) async {
    final ctrl = TextEditingController(text: widget.caption.text);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgSurface,
        title: const Text('Edit caption',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Caption text',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            style: FilledButton.styleFrom(
              backgroundColor: kAccentCyan,
              foregroundColor: Colors.black,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (res != null) {
      widget.caption.text = res;
      widget.state.notify();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cap = widget.caption;
    final left = widget.pad + cap.startMs * widget.pxPerMs + _dragDx;
    final width =
        ((cap.endMs - cap.startMs) * widget.pxPerMs).clamp(20.0, 1e6);
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: width,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              widget.state.selectedOverlayId = cap.id;
              widget.onSeek(cap.startMs);
            },
            onDoubleTap: () => _editCaption(context),
            onHorizontalDragUpdate: (d) {
              setState(() => _dragDx += d.delta.dx);
              widget.state.positionMs =
                  (cap.startMs + (_dragDx / widget.pxPerMs).round())
                      .clamp(0, widget.state.totalDurationMs);
            },
            onHorizontalDragEnd: (_) {
              final dMs = (_dragDx / widget.pxPerMs).round();
              final dur = cap.endMs - cap.startMs;
              final newStart = (cap.startMs + dMs)
                  .clamp(0, widget.state.totalDurationMs);
              cap.startMs = newStart;
              cap.endMs =
                  (newStart + dur).clamp(0, widget.state.totalDurationMs);
              setState(() => _dragDx = 0);
              HapticFeedback.selectionClick();
              widget.state.notify();
            },
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF552288),
                border: Border.all(
                  color: widget.selected
                      ? Colors.white
                      : Colors.purpleAccent.withValues(alpha: 0.6),
                  width: widget.selected ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.centerLeft,
              child: Text(
                cap.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                ),
              ),
            ),
          ),
          if (widget.selected) ...[
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  final dMs = (d.delta.dx / widget.pxPerMs).round();
                  cap.startMs = (cap.startMs + dMs)
                      .clamp(0, cap.endMs - 100);
                  widget.state.notify();
                },
                child: Container(color: Colors.white),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  final dMs = (d.delta.dx / widget.pxPerMs).round();
                  cap.endMs = (cap.endMs + dMs)
                      .clamp(cap.startMs + 100, widget.state.totalDurationMs);
                  widget.state.notify();
                },
                child: Container(color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StickersLane extends StatelessWidget {
  const _StickersLane({
    required this.state,
    required this.pxPerMs,
    required this.pad,
    required this.contentW,
    required this.onSeek,
  });
  final EditorState state;
  final double pxPerMs;
  final double pad;
  final double contentW;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EditorSelection>(
      valueListenable: state.selectionNotifier,
      builder: (_, sel, __) {
        return SizedBox(
          width: contentW,
          height: kTrackHeight,
          child: Stack(
            children: [
              Positioned(
                left: pad,
                right: pad,
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              for (final s in state.stickers)
                _StickerBlock(
                  state: state,
                  sticker: s,
                  pxPerMs: pxPerMs,
                  pad: pad,
                  selected: sel.overlayId == s.id,
                  onSeek: onSeek,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StickerBlock extends StatefulWidget {
  const _StickerBlock({
    required this.state,
    required this.sticker,
    required this.pxPerMs,
    required this.pad,
    required this.selected,
    required this.onSeek,
  });
  final EditorState state;
  final StickerOverlay sticker;
  final double pxPerMs;
  final double pad;
  final bool selected;
  final ValueChanged<int> onSeek;

  @override
  State<_StickerBlock> createState() => _StickerBlockState();
}

class _StickerBlockState extends State<_StickerBlock> {
  double _dragDx = 0;

  @override
  Widget build(BuildContext context) {
    final s = widget.sticker;
    final left = widget.pad + s.startMs * widget.pxPerMs + _dragDx;
    final width = ((s.endMs - s.startMs) * widget.pxPerMs).clamp(20.0, 1e6);
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: width,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              widget.state.selectedOverlayId = s.id;
              widget.onSeek(s.startMs);
            },
            onHorizontalDragUpdate: (d) {
              setState(() => _dragDx += d.delta.dx);
              widget.state.positionMs =
                  (s.startMs + (_dragDx / widget.pxPerMs).round())
                      .clamp(0, widget.state.totalDurationMs);
            },
            onHorizontalDragEnd: (_) {
              final dMs = (_dragDx / widget.pxPerMs).round();
              final dur = s.endMs - s.startMs;
              final newStart =
                  (s.startMs + dMs).clamp(0, widget.state.totalDurationMs);
              s.startMs = newStart;
              s.endMs =
                  (newStart + dur).clamp(0, widget.state.totalDurationMs);
              setState(() => _dragDx = 0);
              HapticFeedback.selectionClick();
              widget.state.notify();
            },
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFC54B96),
                border: Border.all(
                  color: widget.selected
                      ? Colors.white
                      : Colors.pinkAccent.withValues(alpha: 0.5),
                  width: widget.selected ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.centerLeft,
              child: const Icon(Icons.emoji_emotions,
                  color: Colors.white, size: 12),
            ),
          ),
          if (widget.selected) ...[
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  final dMs = (d.delta.dx / widget.pxPerMs).round();
                  s.startMs = (s.startMs + dMs).clamp(0, s.endMs - 100);
                  widget.state.notify();
                },
                child: Container(color: Colors.white),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  final dMs = (d.delta.dx / widget.pxPerMs).round();
                  s.endMs = (s.endMs + dMs)
                      .clamp(s.startMs + 100, widget.state.totalDurationMs);
                  widget.state.notify();
                },
                child: Container(color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
