import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'editor_state.dart';

const int _kSchemaVersion = 1;
const String _kKeyPrefix = 'minis_editor.project_v1.';

/// Persists/restores [EditorState] for a given video path so a user can
/// reopen the editor and resume mid-edit.
class ProjectIO {
  ProjectIO._();

  static String _key(String videoPath) => '$_kKeyPrefix${videoPath.hashCode}';

  static Future<void> save(EditorState s) async {
    if (s.totalDurationMs <= 0) return;
    final json = jsonEncode(_toMap(s));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(s.videoPath), json);
  }

  static Future<bool> restore(EditorState s) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(s.videoPath));
    if (raw == null) return false;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if ((m['v'] as int? ?? 0) != _kSchemaVersion) return false;
      _fromMap(s, m);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clear(String videoPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(videoPath));
  }

  static Map<String, dynamic> _toMap(EditorState s) {
    return {
      'v': _kSchemaVersion,
      'videoPath': s.videoPath,
      'aspect': s.aspect.index,
      'bgMode': s.bgMode.index,
      'bgColor': s.bgColor.toARGB32(),
      'bgImagePath': s.bgImagePath,
      'filter': s.filter.index,
      'filterIntensity': s.filterIntensity,
      'adjust': {
        'brightness': s.adjust.brightness,
        'contrast': s.adjust.contrast,
        'saturation': s.adjust.saturation,
        'brilliance': s.adjust.brilliance,
        'sharpen': s.adjust.sharpen,
        'clarity': s.adjust.clarity,
        'temperature': s.adjust.temperature,
        'tint': s.adjust.tint,
        'vibrance': s.adjust.vibrance,
      },
      'clipMuted': s.clipMuted,
      'clipSpeed': s.clipSpeed,
      'clipVolume': s.clipVolume,
      'coverMs': s.coverMs,
      'keepMusicTempo': s.keepMusicTempo,
      'snapEnabled': s.snapEnabled,
      'frameRateHint': s.frameRateHint,
      'pxPerMs': s.timelinePxPerMs,
      'clips': [
        for (final c in s.clips)
          {
            'id': c.id,
            'inMs': c.inMs,
            'outMs': c.outMs,
            'speed': c.speed,
            'muted': c.muted,
            'reversed': c.reversed,
          }
      ],
      'texts': [
        for (final t in s.texts)
          {
            'id': t.id,
            'text': t.text,
            'startMs': t.startMs,
            'endMs': t.endMs,
            'lane': t.lane,
            'hidden': t.hidden,
            'posX': t.position.dx,
            'posY': t.position.dy,
            'scale': t.scale,
            'rotation': t.rotation,
            'flipH': t.flipH,
            'fontSize': t.fontSize,
            'color': t.color.toARGB32(),
            'bgColor': t.bgColor?.toARGB32(),
            'bold': t.bold,
            'italic': t.italic,
            'fontFamily': t.fontFamily,
            'align': t.align.index,
          }
      ],
      'audios': [
        for (final a in s.audios)
          {
            'id': a.id,
            'path': a.path,
            'label': a.label,
            'startMs': a.startMs,
            'inMs': a.inMs,
            'outMs': a.outMs,
            'volume': a.volume,
            'muted': a.muted,
            'fadeInMs': a.fadeInMs,
            'fadeOutMs': a.fadeOutMs,
          }
      ],
      'captions': [
        for (final cap in s.captions)
          {
            'id': cap.id,
            'text': cap.text,
            'startMs': cap.startMs,
            'endMs': cap.endMs,
          }
      ],
      'export': {
        'resolution': s.export.resolution,
        'frameRate': s.export.frameRate,
        'opticalFlow': s.export.opticalFlow,
        'bitrate': s.export.bitrate,
      },
    };
  }

  static void _fromMap(EditorState s, Map<String, dynamic> m) {
    s.aspect = AspectMode.values[(m['aspect'] as int? ?? 0)
        .clamp(0, AspectMode.values.length - 1)];
    s.bgMode = BackgroundMode.values[(m['bgMode'] as int? ?? 0)
        .clamp(0, BackgroundMode.values.length - 1)];
    if (m['bgColor'] is int) s.bgColor = Color(m['bgColor'] as int);
    s.bgImagePath = m['bgImagePath'] as String?;
    s.filter = FilterPreset.values[(m['filter'] as int? ?? 0)
        .clamp(0, FilterPreset.values.length - 1)];
    s.filterIntensity = (m['filterIntensity'] as num?)?.toDouble() ?? 1.0;
    final adj = m['adjust'] as Map<String, dynamic>?;
    if (adj != null) {
      s.adjust
        ..brightness = (adj['brightness'] as num?)?.toDouble() ?? 0
        ..contrast = (adj['contrast'] as num?)?.toDouble() ?? 0
        ..saturation = (adj['saturation'] as num?)?.toDouble() ?? 0
        ..brilliance = (adj['brilliance'] as num?)?.toDouble() ?? 0
        ..sharpen = (adj['sharpen'] as num?)?.toDouble() ?? 0
        ..clarity = (adj['clarity'] as num?)?.toDouble() ?? 0
        ..temperature = (adj['temperature'] as num?)?.toDouble() ?? 0
        ..tint = (adj['tint'] as num?)?.toDouble() ?? 0
        ..vibrance = (adj['vibrance'] as num?)?.toDouble() ?? 0;
    }
    s.clipMuted = m['clipMuted'] as bool? ?? false;
    s.clipSpeed = (m['clipSpeed'] as num?)?.toDouble() ?? 1.0;
    s.clipVolume = (m['clipVolume'] as num?)?.toDouble() ?? 1.0;
    s.coverMs = m['coverMs'] as int? ?? 0;
    s.keepMusicTempo = m['keepMusicTempo'] as bool? ?? true;
    s.snapEnabled = m['snapEnabled'] as bool? ?? true;
    s.frameRateHint = m['frameRateHint'] as int? ?? 30;
    s.timelinePxPerMs = (m['pxPerMs'] as num?)?.toDouble() ?? 0.06;

    s.clips
      ..clear()
      ..addAll([
        for (final c in (m['clips'] as List? ?? const []))
          ClipSegment(
            id: c['id'] as String,
            inMs: c['inMs'] as int,
            outMs: c['outMs'] as int,
            speed: (c['speed'] as num?)?.toDouble() ?? 1.0,
            muted: c['muted'] as bool? ?? false,
            reversed: c['reversed'] as bool? ?? false,
          )
      ]);

    s.texts
      ..clear()
      ..addAll([
        for (final t in (m['texts'] as List? ?? const []))
          TextOverlay(
            id: t['id'] as String,
            text: t['text'] as String? ?? '',
            startMs: t['startMs'] as int? ?? 0,
            endMs: t['endMs'] as int? ?? 0,
            lane: t['lane'] as int? ?? 0,
            hidden: t['hidden'] as bool? ?? false,
            position: Offset(
              (t['posX'] as num?)?.toDouble() ?? 0.5,
              (t['posY'] as num?)?.toDouble() ?? 0.4,
            ),
            scale: (t['scale'] as num?)?.toDouble() ?? 1.0,
            rotation: (t['rotation'] as num?)?.toDouble() ?? 0.0,
            flipH: t['flipH'] as bool? ?? false,
            fontSize: (t['fontSize'] as num?)?.toDouble() ?? 36,
            color: Color(t['color'] as int? ?? 0xFFFFFFFF),
            bgColor: t['bgColor'] is int ? Color(t['bgColor'] as int) : null,
            bold: t['bold'] as bool? ?? false,
            italic: t['italic'] as bool? ?? false,
            fontFamily: t['fontFamily'] as String? ?? 'Roboto',
            align: TextAlign.values[(t['align'] as int? ?? 2)
                .clamp(0, TextAlign.values.length - 1)],
          )
      ]);

    s.audios
      ..clear()
      ..addAll([
        for (final a in (m['audios'] as List? ?? const []))
          AudioTrack(
            id: a['id'] as String,
            path: a['path'] as String? ?? '',
            label: a['label'] as String? ?? 'Audio',
            startMs: a['startMs'] as int? ?? 0,
            inMs: a['inMs'] as int? ?? 0,
            outMs: a['outMs'] as int? ?? 0x7fffffff,
            volume: (a['volume'] as num?)?.toDouble() ?? 1.0,
            muted: a['muted'] as bool? ?? false,
            fadeInMs: a['fadeInMs'] as int? ?? 0,
            fadeOutMs: a['fadeOutMs'] as int? ?? 0,
          )
      ]);

    s.captions
      ..clear()
      ..addAll([
        for (final c in (m['captions'] as List? ?? const []))
          Caption(
            id: c['id'] as String,
            text: c['text'] as String? ?? '',
            startMs: c['startMs'] as int? ?? 0,
            endMs: c['endMs'] as int? ?? 0,
          )
      ]);

    final ex = m['export'] as Map<String, dynamic>?;
    if (ex != null) {
      s.export
        ..resolution = ex['resolution'] as int? ?? 540
        ..frameRate = ex['frameRate'] as int? ?? 30
        ..opticalFlow = ex['opticalFlow'] as bool? ?? false
        ..bitrate = ex['bitrate'] as int? ?? 7;
    }
  }
}

class OnboardingPrefs {
  OnboardingPrefs._();
  static const _kSeen = 'minis_editor.onboarding_seen_v1';

  static Future<bool> seen() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kSeen) ?? false;
  }

  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSeen, true);
  }
}
