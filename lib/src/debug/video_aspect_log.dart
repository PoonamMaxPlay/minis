import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:loopit_minis/src/sys/video_player_shim.dart';

/// Same fields as LoopIt [logVideoAspectDiag] for comparing merge output vs playback.
void logMinisVideoAspectDiag(String layer, VideoPlayerValue value,
    {String? pathHint}) {
  if (!kDebugMode || !value.isInitialized) return;

  final w = value.size.width;
  final h = value.size.height;
  final rot = value.rotationCorrection;
  final dispW = (rot % 180 == 90) ? h : w;
  final dispH = (rot % 180 == 90) ? w : h;
  final branchByCoded = w < h ? 'portrait_cover' : 'landscape_fitWidth';
  final branchByDisplay =
      dispW < dispH ? 'portrait_cover' : 'landscape_fitWidth';

  dev.log(
    'layer=$layer rotationCorrection=$rot '
    'codedSize=$w' 'x$h '
    'displaySize=$dispW' 'x$dispH '
    'aspectRatioGetter=${value.aspectRatio.toStringAsFixed(4)} '
    'uiBranchFromCodedSize=$branchByCoded uiBranchFromDisplaySize=$branchByDisplay '
    'branchMismatch=${branchByCoded != branchByDisplay} path=$pathHint',
    name: 'VideoAspectDiag',
  );
}
