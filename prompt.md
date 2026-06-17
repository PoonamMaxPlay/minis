# Minis Plugin — Resume Context

## Where
Workspace: /Volumes/KRYPTIX/test/minis/
Type: Flutter plugin (loopit_minis), federated Android (Kotlin) + iOS (Swift).
Example app: /Volumes/KRYPTIX/test/minis/example/ — runnable, contains real screens (reel/story/feed) mirroring host app behavior.
Not a git repo at this path (no .git).

## Mission
Convert `minis` plugin into enterprise-level camera + image editor + video editor. Constraints:
- All work happens INSIDE the plugin. Host app stays untouched.
- All media/system logic moves to NATIVE: Kotlin + Swift + C/C++ (FFmpeg, OpenGL ES, Metal, MediaCodec, VideoToolbox, CameraX, AVFoundation, ExoPlayer, AVPlayer, Oboe, AVAudioEngine, MLKit, Vision, RNNoise, WebRTC AEC3).
- FFmpeg compiled from source as native libs (.so / .xcframework). No Dart wrapper around FFmpeg.
- ZERO Dart media/system packages remain. Dart side = thin MethodChannel + EventChannel + PlatformView shells only.
- Keep `get` (state mgmt) for now — out of scope.

## Current pubspec.yaml deps to KILL (all still present, none removed yet)
camera, pro_image_editor, emoji_picker_flutter, pro_video_editor, video_trimmer, video_compress, video_thumbnail (+packages/video_thumbnail_mock + dependency_overrides), audio_waveforms, audio_session, image_picker, file_picker, video_player, path_provider, path, permission_handler, device_info_plus, wakelock_plus, phosphor_flutter.

## Existing native code (do not delete blindly — refactor)
Android: android/src/main/kotlin/com/loopit/minis/
  LoopitMinisPlugin.kt, MinisCameraXBridge.kt, MinisNativeCameraPlatformView.kt, MinisPreviewPlayer.kt
iOS: ios/Classes/
  LoopitMinisPlugin.swift, MinisPreviewPlayer.swift

## Dart src to refactor (lib/src/independent/)
camera_plugin_minis_engine.dart, native_android_minis_camera_engine.dart, minis_camera_engine_factory.dart, minis_capture_screen.dart, minis_camera_performance.dart, minis_recording_clip.dart, minis_multiclip_merge.dart, minis_h264_repair_transcode.dart, minis_video_file_ready.dart, minis_video_duration.dart, minis_video_preview_page.dart, minis_gallery_preview.dart, minis_reel_clip_trimmer_page.dart, minis_music_trim_sheet.dart, minis_music_trim_math.dart, minis_music_segment.dart, minis_preview_player.dart.

## Planning docs (already written, read them)
/Volumes/KRYPTIX/test/minis/improvement1.md — Native Camera Engine (12 tasks A1–A12)
/Volumes/KRYPTIX/test/minis/improvement2.md — Native Image Editor (12 tasks B1–B12)
/Volumes/KRYPTIX/test/minis/improvement3.md — Native Video Editor + FFmpeg (13 tasks C1–C13)
/Volumes/KRYPTIX/test/minis/improvement4.md — Native Audio Engine (12 tasks D1–D12)
/Volumes/KRYPTIX/test/minis/improvement5.md — Native Media I/O + Pickers + Player + System (11 tasks E1–E11)
/Volumes/KRYPTIX/test/minis/task.md — 65 detailed task prompts across Sections A–F (F = cross-cutting: CI, migration guide, telemetry, integration tests).
/Volumes/KRYPTIX/test/minis/complete.md — tracking table + pub-dep kill-tracker. Move tasks here as they ship.

## Naming conventions (used everywhere)
MethodChannel: loopit/minis/<area>      areas: camera, imgedit, videdit, audio, picker, permissions, paths, player, device, wakelock, emoji_picker, telemetry
EventChannel:  loopit/minis/<area>/<stream>
PlatformView:  loopit/minis/<area>/<view>
Android root: android/src/main/kotlin/com/loopit/minis/<area>/  +  android/src/main/cpp/<area>/
iOS root:     ios/Classes/<Area>/  +  ios/Classes/<Area>/c|cpp/
Dart wrappers: lib/src/native/<area>_channel.dart (channel + typed models, NO logic)

## Min OS targets
Android 8.0 (API 26) minimum; HDR/multicam features gate at API 33+.
iOS 14.0 minimum.

## Workflow rule
1. Pick next undone task from task.md (top of section).
2. Execute prompt; record commands.
3. When acceptance passes → move block to complete.md with date stamp + summary; flip status in table; check pub-dep kill-tracker if applicable.
4. Update downstream tasks whose assumptions changed.

## Verify gate (after every task)
flutter analyze (clean), example builds, flutter pub deps shows removed packages gone when applicable.

## Gitignore
*.md is in .gitignore — planning docs not uploaded to git. Code stays unignored.

## Caveman mode
Active. Drop articles/filler/pleasantries/hedging. Fragments OK. Code/commits/security: normal prose.

## Resume action
Read task.md , all the improvement1.md - improvement5.md and complete.md. Report which task is next in line (lowest ID with status=pending) and proceed only when I say "go <task-id>". update the task.md too along with all improvements completion status in %.
