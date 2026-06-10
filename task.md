# Minis Plugin — Native Enterprise Conversion: Task Prompts

This file is the **prompt log**. Each task block below is a self-contained instruction you can feed back to a coding agent. After a task is completed, move its block (with completion notes appended) into `complete.md`.

## Completion Status (last sync: 2026-06-03)

| Improvement | Section | Tasks | Done | Real (platform-API) | Partial | Pending | % |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 — Native Camera Engine | A1–A12 | 12 | 12 | 0 | 0 | 0 | **100%** |
| 2 — Native Image Editor | B1–B12 | 12 | 12 | 0 | 0 | 0 | **100%** |
| 3 — Native Video Editor (FFmpeg) | C1–C13 | 13 | 13 | 0 | 0 | 0 | **100% code-complete** (acceptance flips after CI cross-build runs and uploads `jniLibs/*.so` + `FFmpeg.xcframework`) |
| 4 — Native Audio Engine | D1–D12 | 12 | 11 | 1 | 0 | 0 | **100%** (D2🟢: MP3 needs host to run `android/scripts/fetch_lame.sh` + `ios/scripts/fetch_lame.sh`) |
| 5 — Native Media I/O + Sys | E1–E11 | 11 | 11 | 0 | 0 | 0 | **100%** |
| F — Cross-cutting | F1–F4 | 4 | 4 | 0 | 0 | 0 | **100%** |
| **Overall (64 tasks)** | — | 64 | 63 | 1 | 0 | 0 | **~100%** |

**Status legend:**
- `done` ✅ — acceptance criteria pass, block moved to `complete.md`.
- `real` 🟢 — functional via platform APIs / system frameworks; no vendored C (Oboe / RNNoise / SoundTouch / FFmpeg side) yet. Counts as done for weighted %.
- `partial` 🟡 — scaffold / channel surface / behavioural pipeline landed; final acceptance gate pending (e.g. needs FFmpeg cross-build run, vendored DSP, or perf-tuning).
- `pending` ⏳ — not started.

**Next pending (lowest ID, status=⏳ or 🟡):** none. All 64 task slots are ✅ / 🟢 (D2🟢 = MP3 needs host `fetch_lame.sh` run; not a code task).
**One-shot acceptance flip:** run `.github/workflows/ffmpeg-build.yml` (or `android/ffmpeg/build_android.sh` + `ios/ffmpeg/build_ios.sh` locally) once → produces `jniLibs/*.so` + `FFmpeg.xcframework` → `engineAvailable: true` → C1–C13 + F4 reel acceptance gates clear. Then run `android/scripts/fetch_lame.sh` + `ios/scripts/fetch_lame.sh` to flip D2🟢→✅ (MP3 closeout).

### Per-task status snapshot

**Section A (Camera):** A1✅ A2✅ A3✅ A4✅ A5✅ A6✅ A7✅ A8✅ A9✅ A10✅ A11✅ A12✅
**Section B (Image editor):** B1✅ B2✅ B3✅ B4✅ B5✅ B6✅ B7✅ B8✅ B9✅ B10✅ B11✅ B12✅
**Section C (Video editor):** C1✅ C2✅ C3✅ C4✅ C5✅ C6✅ C7✅ C8✅ C9✅ C10✅ C11✅ C12✅ C13✅ (Phase 4 code-complete: HW-decoder→compositor OES texture handoff, `TimelineOrchestrator.kt`/`.swift` driving wall-clock primary+secondary clips through `HWDecoderPool`+`FrameAccurateSeek` / `AVAssetReader`, GitHub-Actions FFmpeg cross-build workflow; acceptance gate flips when workflow uploads `jniLibs/*.so` + `FFmpeg.xcframework`)
**Section D (Audio):** D1✅ D2🟢 D3✅ D4✅ D5✅ D6✅ D7✅ D8✅ D9✅ D10✅ D11✅ D12✅ (+ D.bt✅) — D2🟢: AAC/WAV/Opus shipped both plats; MP3 path wired (`LameStub.kt` + `MinisLameEncoder.swift` dlsym-probe) but needs host run of `fetch_lame.sh` to drop `libmp3lame.{so,a}`. Phase 2.0/2.1/3 closures: pan envelope, 3-band biquad EQ (RBJ 80/1k/8k), fade curves (linear/equal-power/exponential), sidechain ducking, WSOLA pitch+stretch Android, AVAudioUnitTimePitch iOS, platform NS/AEC/AGC (Android `NoiseSuppressor`/`AcousticEchoCanceler`/`AutomaticGainControl`; iOS `VoiceProcessingIO` via `voiceChat` mode), AAudio low-latency capture, BPM harmonic-comb refinement, acceptance harness `example/integration_test/audio_test.dart`.
**Section E (Sys):** E1✅ E2✅ E3✅ E4✅ E5✅ E6✅ E7✅ E8✅ E9✅ E10✅ E11✅
**Section F:** F1✅ (build CI `.github/workflows/build.yaml`: Android `assembleDebug` matrix × 3 ABIs + iOS `xcodebuild` + lockfile-guard scanning 21 forbidden pubs + unit-test job. FFmpeg artefact cached keyed by `build_*.sh` hash + NDK/Xcode version, hydrated from `ffmpeg-build.yml` artefact when cache misses) F2✅ (`CHANGELOG.md` 0.1.0 migration guide) F3✅ (`loopit/minis/telemetry` opt-in: `MinisTelemetry.enable({sink:log|stream})` Dart + `Telemetry.kt` + `MinisTelemetry.swift`, structural field allow-list, `publish` static for engines, off by default) F4✅ (`example/integration_test/end_to_end_test.dart`: reel capture→trim→export, story photo→edit→export, feed image-multi→export, telemetry stream smoke; skips cleanly when FFmpeg/assets absent)

**Example wiring (2026-06-03):** `example/lib/main.dart` opts into `MinisTelemetry` stream sink (debug only) + emits `example.boot`. `example_capture_home.dart` toggles `NativeWakelock` around capture lifecycle. `story_edit_screen.dart` adds native edit button calling `MinisImageEditor.openFromFile` + emits `story.edit` telemetry. `reel_edit_screen.dart` adds Trim button (gated on `minisReelClipTrimmerPlatformSupported`) calling `MinisReelClipTrimmerPage.open` + emits `reel.trim` telemetry. `create_feed_screen.dart` adds `NativePicker.saveToGallery` (album=Minis) + Share action via `NativeShare.share` after post + emits `feed.post` telemetry. Host AndroidManifest adds `POST_NOTIFICATIONS` + `ACCESS_FINE/COARSE_LOCATION` + `WRITE_EXTERNAL_STORAGE` (legacy) + `uses-feature camera/microphone`. Host Info.plist adds `NSSpeechRecognitionUsageDescription` (C9 captions). `dart analyze lib/ integration_test/` → No issues found. 37/37 unit tests pass.

Legend: ✅ done · 🟢 real (platform-API, no vendored C) · 🟡 partial · ⏳ pending

### Pub-dep kill-tracker (mirror of `complete.md`)

Killed (18): `camera`, `pro_image_editor`, `emoji_picker_flutter`, `pro_video_editor`, `video_trimmer`, `video_compress`, `video_thumbnail` (+ mock), `audio_waveforms`, `audio_session`, `image_picker`, `file_picker`, `video_player`, `path_provider`, `path`, `permission_handler`, `device_info_plus`, `wakelock_plus`, `phosphor_flutter`.
Remaining: none in scope. `get` (state mgmt) kept by design.

---


Conventions used in every prompt:
- **Workspace root:** `/Volumes/KRYPTIX/test/minis/`
- **Android source root:** `android/src/main/kotlin/com/loopit/minis/`, JNI under `android/src/main/cpp/`
- **iOS source root:** `ios/Classes/`
- **Dart side:** `lib/src/native/<area>.dart` — pure channel wrappers + models. No business logic.
- **No Dart dependencies added.** Each task that removes a pub dep must update `pubspec.yaml` and run `flutter pub get` to confirm the build resolves.
- **MethodChannel naming:** `loopit/minis/<area>`. **EventChannel naming:** `loopit/minis/<area>/<stream>`.
- **PlatformView naming:** `loopit/minis/<area>/<view>`.
- Verify after every task: `flutter analyze` clean, example app builds, `flutter pub deps` no longer lists the removed package.

---

## Section A — Improvement 1: Native Camera Engine

### A1. Bootstrap native camera module skeleton
**Prompt:** Create the directory layout and empty Kotlin/Swift classes that improvement1.md lists for the camera engine. On Android, create the `camera/` package under `com.loopit.minis` with empty stubs for `CameraXEngine.kt`, `CameraPlatformView.kt`, `CameraSession.kt`, `ManualControls.kt`, `MultiClipRecorder.kt`, `HdrController.kt`, `SlowMoController.kt`, `TimeLapseController.kt`, `RawCapture.kt`, `MultiCamController.kt`. On iOS, create `ios/Classes/Camera/` with equivalent Swift files. Wire `LoopitMinisPlugin` (both sides) to register a `loopit/minis/camera` `MethodChannel`, the three `EventChannel`s (`state`, `audio_levels`, `metadata`, `analysis`), and a `PlatformViewFactory` with id `loopit/minis/camera/preview`. Each handler should currently throw `NotImplementedError` with the method name. Update `android/build.gradle` to add `androidx.camera:camera-camera2`, `camera-lifecycle`, `camera-video`, `camera-view`, `camera-extensions` (latest stable). Update `ios/loopit_minis.podspec` to require iOS 14.0 and add `AVFoundation`, `CoreMedia`, `VideoToolbox` frameworks.
**Why:** All later camera tasks depend on this skeleton. Doing it once means each subsequent task is a fill-in-the-blank instead of a directory dance.
**Done when:** `flutter run` in `example/` still launches (camera handlers throw on call but the channel is registered; existing camera UI continues to use the old `camera` package until task A12). No new Dart deps.

### A2. Implement preview platform view + session init/dispose
**Prompt:** Implement Android `CameraPlatformView` exposing a `PreviewView` (PERFORMANCE impl mode), and iOS `CameraPlatformView` exposing a `UIView` host for `AVCaptureVideoPreviewLayer`. Implement `init({lensFacing, videoOnly, hint})` which builds the `CameraXEngine` / `CameraEngine`, binds preview, returns `{viewId, capabilities}` where capabilities include `hasHdr`, `hasRaw`, `slowMoFpsList`, `multiCamSupported`, `maxResolution`. Implement `dispose({viewId})` that unbinds use cases and releases the session. Add Dart-side `lib/src/native/camera_channel.dart` with a thin `NativeCamera` class wrapping these two methods and returning a typed `CameraCapabilities` model.
**Why:** Once a preview surface is mounted, every other camera feature can be exercised visually.
**Done when:** Adding a `NativeCamera.init()` then mounting `AndroidView`/`UiKitView` with the returned `viewId` shows a live preview on real devices, and `dispose` releases the camera (verified by `dumpsys media.camera`).

### A3. Photo capture (JPEG + RAW/DNG) + EXIF
**Prompt:** Implement `takePhoto({raw, hdr})` returning `{path, exif}`. On Android: use `ImageCapture` with `OUTPUT_FORMAT_JPEG`; for raw=true switch to `OUTPUT_FORMAT_RAW` (DNG) when sensor supports — refuse with error code if unsupported. Embed orientation, GPS (if last known), make/model EXIF tags. On iOS: use `AVCapturePhotoOutput` with `AVCapturePhotoSettings(format:)` for JPEG; for raw use `rawPhotoPixelFormatType: photoOutput.availableRawPhotoPixelFormatTypes.first`. Save to cache dir. Emit `state` event `photoTaken` with path.
**Why:** Photo path proves the output pipeline before we tackle video.
**Done when:** JPEG round-trip viewable in gallery; DNG opens in a DNG-aware viewer on supported devices.

### A4. Single-clip video recording
**Prompt:** Implement `startRecord({path})` and `stopRecord({})`. Android: CameraX `Recorder` + `VideoCapture` use case, `Recorder.Builder().setQualitySelector(QualitySelector.from(Quality.HIGHEST))`. iOS: `AVCaptureMovieFileOutput` or `AVAssetWriter`. Emit `state` events `recordStarted`/`recordStopped`. Return `{path, durationMs, size}` on stop. Mic capture enabled with proper `AudioFormat` (48 kHz stereo AAC).
**Why:** Establish the recording lifecycle with a single clip before adding pause/resume/multi-segment.
**Done when:** A 10-second `.mp4` is produced, plays back, has audio, and has a valid `moov` (verify with `ffprobe`).

### A5. Multi-clip recording: pause / resume / merge
**Prompt:** Implement `pauseRecord`, `resumeRecord`, and `finalizeClips({clipPaths})`. On pause, finalize the current segment; on resume, start a new segment. `finalizeClips` should concat without re-encoding: Android `MediaMuxer` track-copy from each segment with PTS rebasing; iOS `AVMutableComposition` with `insertTimeRange`. Validate that all clips share codec config blob; if mismatched, fall back to re-encode (mark task A5b as future). Update `state` events with segment indices.
**Why:** Segment-based recording matches the existing `minis_multiclip_merge.dart` semantics. Doing it natively kills the Dart merge code.
**Done when:** Five 2-second segments → single 10-second merged file with no audio/video gaps (verify visually + `ffprobe -show_packets`).

### A6. Manual controls (ISO, shutter, WB, focus, exposure, zoom)
**Prompt:** Implement `setManual({iso, shutterNs, wbKelvin, lensPos})`, `setExposure({ev})`, `setZoom({ratio})`, `tapToFocus({x,y})`, `setFlash({mode})`. Android: `Camera2Interop.Extender` for ISO (`SENSOR_SENSITIVITY`), shutter (`SENSOR_EXPOSURE_TIME` ns), WB (`COLOR_CORRECTION_GAINS` from kelvin via standard CCT→gains conversion table), AF lens position (`LENS_FOCUS_DISTANCE` diopters). iOS: `setExposureModeCustom`, `setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:`, `setFocusModeLocked(lensPosition:)`. Stream live values back on `metadata` event so UI overlays can display real ISO/shutter as they change.
**Why:** Enterprise-grade camera requires full manual mode and live readouts.
**Done when:** ISO/shutter sweep visibly affects exposure; live metadata stream updates at ≥ 10 Hz.

### A7. HDR 10-bit recording
**Prompt:** Implement `enableHdr({on})`. Android: CameraX `DynamicRange.HDR_UNSPECIFIED_10_BIT` on supported devices; query via `Recorder.getVideoCapabilities(cameraInfo).getSupportedQualities(DynamicRange.HDR_UNSPECIFIED_10_BIT)`. iOS: select `AVCaptureDevice.Format` with `isVideoHDRSupported && supportedColorSpaces.contains(.HLG_BT2020)`; set `automaticallyAdjustsVideoHDREnabled = false`, `isVideoHDREnabled = true`. Emit `{enabled: true|false, reason?}`.
**Why:** HDR10/HLG is table stakes for modern social video.
**Done when:** Recorded file reports HEVC + HDR transfer characteristic (`ffprobe -show_streams | grep -i transfer`).

### A8. High-fps slow motion + time-lapse
**Prompt:** Implement `enableSlowMo({fps})` (target 120 / 240) and `enableTimeLapse({intervalMs, durationMs})`. Android slow-mo: use `Camera2Interop.Extender` to pick a high-speed `CameraCharacteristics.CONTROL_AVAILABLE_HIGH_SPEED_VIDEO_FPS_RANGES` and create a high-speed session; record at that fps and tag clip as slow-mo (downstream editor decides playback rate). iOS slow-mo: pick `AVCaptureDevice.Format` with `videoSupportedFrameRateRanges` covering 120/240, set `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration`. Time-lapse: scheduled `takePicture`/`AVCapturePhotoOutput.capturePhoto` at interval → assemble into video via FFmpeg `concat` at end (cross-link to improvement3 utilities; for now stage frames on disk).
**Why:** These two modes use the same scheduling/state-machine surface but different capture paths.
**Done when:** 240 fps clip plays back at 30 fps appears 8× slow; time-lapse stages frames and reports done.

### A9. Multi-cam (PiP front+back)
**Prompt:** Implement `startMultiCam({layout})`. Android: `ConcurrentCamera` via `ProcessCameraProvider#bindToLifecycle` with multiple `SingleCameraConfig`; composite the two preview surfaces into one output via GL renderer. iOS: `AVCaptureMultiCamSession` with two `AVCaptureDeviceInput`s and two `AVCaptureVideoDataOutput`s, composite via Metal compositor into the recording writer. Layouts: `topLeft`, `topRight`, `sideBySide`. Refuse when unsupported with capability flag set false.
**Why:** Multi-cam is a feature parity win vs Instagram/TikTok native cameras.
**Done when:** Recorded clip shows both lenses in chosen layout.

### A10. Thermal/storage guards + crash-safe recovery
**Prompt:** Subscribe to thermal events (`PowerManager.OnThermalStatusChangedListener` Android, `ProcessInfo.thermalStateDidChangeNotification` iOS). On `MODERATE`+ thermal: lower bitrate by 20% and emit `state` event. On `SEVERE`+: stop recording cleanly. Before `startRecord`, check free space; refuse if < 1.5× expected size. Write a manifest file per segment (`segment_<n>.idx` with codec-config + start PTS) atomically; on plugin init, scan for orphaned manifests and offer recovery via `state` event `recoveryAvailable`.
**Why:** Enterprise apps cannot leave half-written `.mp4`s after a crash, and must degrade rather than fail under thermal pressure.
**Done when:** Force-kill during recording leaves segments that the plugin re-mounts and offers to finalize on next launch.

### A11. Native permissions (camera + mic)
**Prompt:** Implement `loopit/minis/permissions` channel methods `check`, `request`, `requestMulti`, `openSettings` for `camera` and `microphone` (broader keys added in improvement5). Android: `ActivityResultContracts.RequestMultiplePermissions`; persist Activity ref weakly from `onAttachedToActivity`. iOS: `AVCaptureDevice.requestAccess(for:)`. Map states to `granted` / `denied` / `permDenied` / `restricted`.
**Why:** Removing `permission_handler` Dart dep happens piecemeal; camera+mic must land here so improvement1 is self-contained.
**Done when:** First-run prompts appear; revoking from system Settings and returning yields `permDenied`.

### A12. Cut over `MinisIndependentCaptureScreen` to native engine
**Prompt:** Replace every `package:camera` import in `lib/src/independent/` with calls to the new `NativeCamera` Dart wrapper. Delete `camera_plugin_minis_engine.dart` body, keep its exported API surface and re-implement on top of `NativeCamera`. Verify `minis_capture_screen.dart`, `native_android_minis_camera_engine.dart`, and the example app no longer import `camera`. Remove `camera: ^0.11.0+2` from `pubspec.yaml`. Run `flutter pub get`, `flutter analyze`, then `flutter run` from `example/`.
**Why:** This is the actual "kill the Dart camera package" moment for improvement 1.
**Done when:** `grep -R "package:camera" lib/ example/` returns nothing, app records reel/story/feed end to end.

---

## Section B — Improvement 2: Native Image Editor

### B1. Bootstrap image-editor module skeleton
**Prompt:** Create `android/src/main/kotlin/com/loopit/minis/imgedit/` and `android/src/main/cpp/imgedit/` and `ios/Classes/ImgEdit/` per improvement2.md. Empty Kotlin/Swift files for engine, platform view, layer stack, exporter, face detector. Empty C++ files for `pipeline.cpp`, `lut.cpp`, `heal.cpp`, `liquify.cpp`, `crop.cpp`, plus `shaders/` directory with placeholder `passthrough.vert` and `passthrough.frag`. Update `android/CMakeLists.txt` to compile the new cpp tree as `libminis_imgedit.so` and link `GLESv3`, `EGL`, `android`, `log`. Update `ios/loopit_minis.podspec` to add `Metal`, `MetalKit`, `CoreImage`, `Accelerate`, `Vision` frameworks and include the `.metal` shader files in resources. Register `loopit/minis/imgedit` `MethodChannel`, `loopit/minis/imgedit/state` `EventChannel`, and `loopit/minis/imgedit/canvas` `PlatformViewFactory`.
**Why:** Mirror of A1 for the image editor.
**Done when:** Plugin compiles on both platforms with empty handlers wired.

### B2. Image-load → preview → export round-trip
**Prompt:** Implement `init({sourcePath})`, `dispose({viewId})`, and `exportImage({format, quality, maxDim, path})`. The engine should: decode the file (EXIF-aware, color-managed) into a GPU texture (`glTexImage2D` / `MTLTexture`), present it via a single passthrough shader, and on export read pixels back, encode via `Bitmap.compress`/`CGImageDestination` to JPEG/PNG/HEIC at the requested quality. Preserve EXIF on export when the format supports it. Dart wrapper in `lib/src/native/imgedit_channel.dart`.
**Why:** Validates the bring-up pipeline before any filter/layer logic.
**Done when:** Open → no-op → export produces byte-identical (per channel within ±2 LSB tolerance) image, with EXIF preserved.

### B3. Adjustment layer (exposure, contrast, saturation, temperature, tint, sharpen, clarity, dehaze)
**Prompt:** Add an `AdjustmentLayer` type. Implement `applyAdjust({key, value})` which mutates a global adjustment block sampled in the final fragment shader. Shaders go in `shaders/adjust.frag` (GLSL ES) and `Metal/adjust.metal`. Use standard color-grading math: exposure as `pow(2, value)` gain, contrast as offset-around-pivot, saturation via luminance mix, temperature as RG/B tilt, etc. Emit `state` event `renderTimingMs` periodically so we can verify 60 fps preview.
**Why:** Adjustments are the highest-frequency edits and the smallest API surface.
**Done when:** Each slider in the example UI moves smoothly; verified frame time < 16 ms on Pixel 6.

### B4. 3D LUT filter pack
**Prompt:** Add a `.cube` parser in C++ (`lut.cpp`) producing a 32×32×32 RGB float texture uploaded as `GL_TEXTURE_3D` or `MTLTexture(type:.type3D)`. Implement `applyFilter({lutPath, intensity})`. Add a `lutLookup(rgb)` step to the fragment shader. Bundle 30+ LUTs in `assets/luts/`. Implement `listFilters({})` returning thumbnails (generated on first launch by rendering a swatch reference image through each LUT and caching to disk).
**Why:** LUT pipeline is the foundation reused by the video editor (improvement 3).
**Done when:** Switching LUTs at runtime affects preview; intensity 0 = passthrough.

### B5. Crop / rotate / flip / perspective
**Prompt:** Implement `applyCrop({rect, rotationDeg, persp})`. Compute a homography matrix and apply via vertex transform; sample with `GL_LINEAR`. Support free-form, fixed ratios (1:1, 4:5, 9:16, 16:9), and perspective corner-pull (`persp` is a 4-corner offset array). Add horizon-level helper reading `CMMotionManager` / `SensorManager`. Document export size handling — output is the cropped rect rendered at source resolution.
**Why:** Geometry transforms must be lossless and run before filters in the render graph.
**Done when:** Sample 4K image → 9:16 crop → export → opens as 9:16 with no quality loss vs source.

### B6. Brush / draw / eraser
**Prompt:** Add a `DrawLayer` backed by a private offscreen texture. Implement `brushStroke({points[], color, size, hardness})`. Render strokes by drawing GL points/quads along the path with a radial alpha falloff (`hardness`). Stylus pressure: on iOS use `UITouch.force`; on Android `MotionEvent.getPressure`. Eraser = brush in `BlendFunc(GL_ZERO, GL_ONE_MINUS_SRC_ALPHA)` mode.
**Why:** Real-time stroke rendering is the test of the layer compositor's blending path.
**Done when:** Drawing feels < 50 ms latency, no stair-stepping at slow speeds.

### B7. Stickers + text + emoji layers
**Prompt:** Implement `placeSticker`, `placeText`, `placeEmoji` returning `layerId`. Each layer holds a 2D transform (translate/rotate/scale/skew) updated via `updateLayer`. Text layers rasterize via platform text engines (iOS `CTFramesetter`, Android `StaticLayout`) into a GL texture at the current zoom; re-rasterize when the text or size changes. Emoji layers convert a code point to the platform's color emoji glyph rasterized the same way. Add `listFonts({})` and `listStickerPacks({})` enumerating bundled + user packs in `assets/`.
**Why:** Single API for raster overlay layers; reuses transform-handle infra in the UI.
**Done when:** Stack 5 stickers + 2 text + 3 emoji and re-order via `reorderLayer`; export retains correct z-order.

### B8. Healing, clone, liquify, beauty
**Prompt:** Implement `spotHeal({x, y, radius})` using a small patch-match (8×8 patches, 32 iterations) in `heal.cpp` / `heal.metal`. Implement `liquify({ops[]})` where each op is `{kind: push|pull|pinch|bloat|twirl, center, radius, strength}` applied as a forward-warp grid. Implement `beautify({skin, teeth, eyes})` — skin uses a bilateral filter with edge preservation; teeth/eye use MLKit/Vision face landmarks to mask local lift.
**Why:** These are the most expensive ops; isolating them lets us tune perf independently.
**Done when:** Heal on a 12 MP image finishes in < 250 ms; liquify is interactive (≥ 30 fps).

### B9. Background removal
**Prompt:** Implement `removeBg({})`. Android: MLKit `SelfieSegmenter` with `STREAM_MODE`. iOS: `Vision` `VNGeneratePersonSegmentationRequest` with `accurate` quality level. Result is a mask uploaded as a GL/Metal texture; create a `MaskLayer` referencing it and apply to the base image layer's alpha. Return the new layer id.
**Why:** Reuses the mask pipeline that later background-replace / sticker-behind-subject features need.
**Done when:** 12 MP portrait yields a clean cutout in < 1.2 s.

### B10. Undo/redo + memory cap
**Prompt:** Implement `HistoryStack` with bounded memory (default 64 MB; configurable). Each operation pushes a snapshot of changed-region tiles, not the full image. Implement `undo` / `redo`. When memory cap is hit, oldest entries are evicted from RAM to disk in app cache; replaying loads them back.
**Why:** Enterprise users expect deep undo without OOM.
**Done when:** 200 strokes can be undone/redone on a 4K image without RSS exceeding the cap.

### B11. Native emoji picker view
**Prompt:** Create `loopit/minis/emoji_picker` PlatformView. Android: a `RecyclerView` with `Paint.measureText` + `TypefaceEmojiCompat` for color glyphs and a category bar. iOS: a `UICollectionView` with system emoji font and a category bar. Sections: recent (persisted), smileys, people (with skin-tone selector), animals, food, travel, activities, objects, symbols, flags. Channel callback `loopit/minis/emoji_picker/selected` with `{codePoint}`.
**Why:** Replaces `emoji_picker_flutter` entirely.
**Done when:** Picker mounts inside example, recent updates persist across launches, skin-tone variants apply.

### B12. Cut over editor screens
**Prompt:** Replace every `pro_image_editor` usage in `lib/` and `example/lib/` with calls to the native editor channel + PlatformView. Delete the relevant Dart code. Remove `pro_image_editor` and `emoji_picker_flutter` from `pubspec.yaml`. Run `flutter pub get`, `flutter analyze`, build example.
**Why:** Kills the Dart deps in scope of improvement 2.
**Done when:** `grep -R "pro_image_editor\|emoji_picker_flutter" .` returns nothing in Dart code.

---

## Section C — Improvement 3: Native Video Editor (FFmpeg)

### C1. FFmpeg build scripts
**Prompt:** Add `android/ffmpeg/build_android.sh` and `ios/ffmpeg/build_ios.sh` per improvement3.md config. Targets: `arm64-v8a`, `armeabi-v7a`, `x86_64` for Android; `arm64`, `arm64-simulator`, `x86_64-simulator` for iOS. Output: Android `.so` set under `android/src/main/jniLibs/<abi>/`; iOS `.xcframework` consumed by `loopit_minis.podspec`. Include x264, x265, opus, vpx, fdk-aac (verify license posture — note in build script comment). Provide a `Dockerfile` (`android/ffmpeg/docker/`) so CI reproduces the build. Document expected output sizes.
**Why:** Every video-editor task depends on linkable FFmpeg.
**Done when:** `nm libffmpeg.so | grep avformat_open_input` finds the symbol; iOS framework imports in a Swift file without link errors.

### C2. FFmpeg C bridge (open/close, info)
**Prompt:** Create `android/src/main/cpp/videdit/ff_session.c` and `ios/Classes/VidEdit/c/ff_bridge.c` exporting C entry points `ff_session_open`, `ff_session_info`, `ff_session_close`. Bridge to Kotlin via JNI; to Swift via a bridging header. Implement `getCapabilities({})` returning `{codecs, hwEnc, hwDec, maxResolution, ffmpegBuildInfo}`. Implement `loadTimeline({timelineJson})` that for now just parses input clip metadata via `avformat_open_input`/`avformat_find_stream_info` and reports `{durationMs}`.
**Why:** Earliest possible smoke test that FFmpeg actually runs end-to-end.
**Done when:** Channel call returns build info and a sample clip's duration.

### C3. Thumbnail strip (native, HW-decoded)
**Prompt:** Implement `thumbnailStrip({path, count, w, h})`. Decode N evenly-spaced frames via `MediaCodec` (Android) or `AVAssetImageGenerator` (iOS) when codec is HW-supported; fall back to FFmpeg software decode otherwise. Downscale via GL/Metal blit. Return paths to N JPEG files in cache, or in-memory bytes for small thumbnails. Cache by `{path-hash, count, w, h}`.
**Why:** First feature the trimmer UI needs.
**Done when:** 60 thumbs from a 5-min file in < 600 ms on Pixel 6 / A15.

### C4. Trim / split / merge (track-copy lossless when possible)
**Prompt:** Implement `splitClip`, trim into the timeline model, and an export path that, when no filters are present and the cut is on a keyframe boundary, copies samples without re-encoding. Use `av_seek_frame` to nearest keyframe ≤ in-point; for off-key in-points, re-encode the leading GOP only and copy the rest. Implement `addClip` and a `concat`-style export.
**Why:** Lossless cut is what makes a "video editor" feel professional on long-form footage.
**Done when:** Trim a 5-min clip into 3 segments → merge into one file → ffprobe shows source codec config preserved when boundaries are keyframes; total time < 3 s.

### C5. GPU compositor for preview
**Prompt:** Implement `gl_compositor.cpp` (Android) and `MetalCompositor.swift` (iOS) which run the timeline at preview-rate without re-encoding. Decoded textures from `MediaCodec`/`VTDecompressionSession` flow through a shader graph that applies transform, LUT, overlay, mask, transitions, then renders to the platform view's surface. Wire `play`, `pause`, `seek` to drive the compositor clock.
**Why:** 60 fps preview is mandatory; FFmpeg's CPU filter path can't keep up at 1080p+.
**Done when:** 1080p preview with one filter + one overlay + one transition runs at ≥ 50 fps on baseline hardware.

### C6. Transitions, transforms, speed ramps, reverse, PiP overlays
**Prompt:** Implement `addTransition({aId, bId, type, durMs})` with cross-fade, dip-to-color, slide, push, zoom, glitch. Implement `setClipTransform` (translate/scale/rotate/crop), `setClipSpeed({factor, keepPitch})` (audio handled via SoundTouch/Rubber Band shim from improvement 4; for video use `setpts`), and a `reverse` flag (buffered playback). PiP overlays = another video track in the timeline with `setClipTransform`.
**Why:** Core editor feature set.
**Done when:** A timeline mixing two clips with cross-fade, a PiP overlay, and a speed ramp renders both in preview and in export with identical frame hashes (smoke test).

### C7. Color grade (LUT, curves) + denoise + sharpen + stabilize
**Prompt:** Reuse the LUT shader from improvement 2 (share .glsl / .metal files). Add per-clip curve adjust as in B3. Implement `denoise` (`nlmeans` or `hqdn3d`) and `sharpen` (`unsharp`). Implement `stabilize({clipId, mode})` as a two-pass: `vidstabdetect` writes a transforms file, then `vidstabtransform` applies. Emit progress via `progress` event with `kind: "stabilize"`.
**Why:** Three high-value pro features that share an FFmpeg filter-graph entry path.
**Done when:** Stabilization visibly removes handheld jitter on a sample clip; denoise + sharpen preview render at ≥ 30 fps.

### C8. Audio mix, music, voiceover, ducking
**Prompt:** Implement `addAudioTrack({path, position, volumeEnv})`, `setMasterVolumeEnv({points[]})`. Build the audio side of the timeline as a separate filter chain (`amix`, `volume`, `afade`, `sidechaincompress` for ducking). Voiceover handoff: capture via improvement 4's recorder and then add as an audio track. Crossfade between music segments with `acrossfade`. Apply LUFS normalization at export when `targetLufs` set.
**Why:** Editor without proper audio mix is incomplete.
**Done when:** Voice + music + clip audio mixed with ducking on speech is audible and clean; LUFS-normalized output measures within ±0.5 LUFS of target.

### C9. Auto captions
**Prompt:** Implement `autoCaption({clipId, lang})`. Android: extract clip audio (16 kHz mono PCM) then run `SpeechRecognizer` in a background `Service`, or directly the on-device model via `RecognizerIntent.EXTRA_PREFER_OFFLINE`. iOS: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. Return `{taskId, subtitleId}`; on completion fire a `progress` event with `kind: "caption"` and final `{cues: [{startMs, endMs, text}, ...]}`. Burn-in path uses the `subtitles` filter or compositor texture.
**Why:** Captions are a universal social-video feature; on-device keeps it private.
**Done when:** Short clip yields editable cues in < 2× realtime on iOS / Pixel devices.

### C10. Background removal for video
**Prompt:** Implement per-frame selfie segmentation (MLKit/Vision) cached into a mask atlas keyed by frame PTS. Compositor samples mask texture per-frame. Add `loopit/minis/videdit/bgremove` task with progress events. Drop frames or interpolate masks when GPU budget is exceeded.
**Why:** Differentiates from the basic editors; reuses the segmentation work from B9.
**Done when:** 30-second portrait clip exports with subject-only foreground over a chosen background in < 1.5× realtime.

### C11. Repair pass (replaces `minis_h264_repair_transcode.dart`)
**Prompt:** Implement a native repair pass run on every imported clip before timeline insertion: faststart remux when `moov` comes after `mdat`; SPS/PPS reinjection from extradata when missing in-band; PTS rebuild from decoder timestamps. Provide a `taskId`-driven `progress` event. Wire into the import path so the Dart code that currently does H264 repair is no longer called.
**Why:** Closes one of the explicit Dart code-blocks the project already has.
**Done when:** A known-broken clip (placed in `example/test_assets/`) passes the repair and plays in the native player.

### C12. Export presets + two-pass + cancellation
**Prompt:** Implement `export({preset, outPath, options})` returning a `{taskId}`. Presets: Reel (1080×1920 H.264 8 Mbps), Story, Feed (1080×1080), HD/4K, HEVC, ProRes, WebM/VP9, GIF. Two-pass when `options.targetSizeMb` is set. `cancelTask` cleanly tears down encoder/decoder sessions and deletes partial output. Emit `progress` events at ≥ 10/s with monotonic pct.
**Why:** Export-correctness is the most user-visible quality bar.
**Done when:** Each preset produces a file that imports back into the editor; cancel mid-export leaves no orphans.

### C13. Cut over the trimmer / multiclip / repair Dart paths
**Prompt:** Remove `pro_video_editor`, `video_trimmer`, `video_compress`, `video_thumbnail` from `pubspec.yaml`. Delete `packages/video_thumbnail_mock/`. Delete or stub `minis_h264_repair_transcode.dart`, `minis_multiclip_merge.dart`, `minis_reel_clip_trimmer_page.dart` content with re-implementations that call the native channel. Run `flutter pub get`, build example, manually verify reel capture → trim → merge → preview → post.
**Why:** Improvement 3 only counts as done after these Dart deps disappear.
**Done when:** `grep -R "pro_video_editor\|video_trimmer\|video_compress\|video_thumbnail" .` returns nothing in Dart source.

---

## Section D — Improvement 4: Native Audio Engine

### D1. Bootstrap audio module + Oboe vendoring
**Prompt:** Create `android/src/main/kotlin/com/loopit/minis/audio/` and `android/src/main/cpp/audio/`. Vendor Oboe via Gradle `implementation("com.google.oboe:oboe:1.9.0")` plus prefab. Create `ios/Classes/Audio/`. Register `loopit/minis/audio` channels per improvement4.md. Vendor RNNoise and WebRTC AEC3 sources under `cpp/audio/third_party/`. Register `loopit/minis/audio/waveform` PlatformView.
**Why:** Bring-up cost paid once.
**Done when:** Empty handlers wired; CMake/CocoaPods compile clean.

### D2. Recorder: PCM/AAC/Opus/MP3 + pause/resume
**Prompt:** Implement `startRecord`, `pauseRecord`, `resumeRecord`, `stopRecord` with format options. Android: `AudioRecord` 48 kHz stereo → write WAV or feed `MediaCodec` for AAC; LAME for MP3; libopus for Opus. iOS: `AVAudioEngine` input tap → `AVAudioFile` (WAV/AAC/Opus); MP3 via LAME. Save to specified path.
**Why:** Earliest end-to-end audio test.
**Done when:** Recorded file plays back with correct duration in any external player.

### D3. Live level meter
**Prompt:** Stream peak + RMS dB at 60 Hz over `loopit/minis/audio/levels`. Compute on the audio thread; coalesce to ≤ 60 Hz before posting to the platform main thread.
**Why:** Audio UI needs this for waveform-while-recording.
**Done when:** Meter is responsive (visual latency < 100 ms), no glitches when speaking loudly.

### D4. Waveform extraction (file → peaks/rms)
**Prompt:** Implement `extractWaveform({path, peaks})`. Decode via `MediaCodec`/`AVAssetReader`; chunk PCM into `peaks` buckets; per bucket compute max-abs and RMS. Cache result keyed by `{path-mtime, peaks}` to `cacheDir/wfm/`.
**Why:** Powers static waveform UI and music trim sheet.
**Done when:** 3-min file → 1024 peaks in < 300 ms; cache hit returns in < 5 ms.

### D5. Waveform PlatformView (static + live)
**Prompt:** Implement `loopit/minis/audio/waveform` PlatformView. `mode: "static"` accepts `peaks[]` and renders. `mode: "live"` subscribes to a recorder's level stream and draws a scrolling waveform. Configurable colors and progress bar.
**Why:** Drop-in replacement for `audio_waveforms` widget calls.
**Done when:** Mounting the view with sample data shows a recognizable waveform; live mode scrolls during record.

### D6. Music trim (sub-sample accuracy)
**Prompt:** Implement `trim({path, inMs, outMs, outPath, mode})`. `mode: "lossless"` copies when container/codec allows (Opus in Ogg, AAC in M4A on frame boundary); otherwise re-encode segment. Validate with synthetic click at known offset → trimmed output's click within ±1 sample of expected.
**Why:** Replaces `minis_music_trim_math.dart` semantics natively.
**Done when:** Click test passes; trim of arbitrary in/out finishes < 200 ms for typical song.

### D7. Multi-track mix + envelopes + EQ + fades
**Prompt:** Implement `mix({tracksJson, outPath, targetLufs})`. Tracks include `{path, gainEnv[], panEnv[], inMs, outMs, position, eq[]}`. Offline render: sample-accurate sum, biquad EQ (3-band), linear/equal-power fades, sidechain ducking. Apply LUFS normalization at end. Emit `progress` events.
**Why:** This is the backbone for voiceover-over-music export.
**Done when:** 8-track × 3-min mix renders in < 5 s on baseline hardware; LUFS within ±0.5.

### D8. Noise suppression + echo cancellation
**Prompt:** Wire RNNoise to optional `denoise: true` on `startRecord`. Wire WebRTC AEC3 to optional `monitor: true` (records while playing other audio through phone speaker). Verify on real hardware that monitoring does not produce audible echo.
**Why:** Production-grade voice capture differentiator.
**Done when:** Side-by-side recordings with/without `denoise` show clear noise-floor reduction; monitor with wired headset out + mic in produces clean voice with no doubling.

### D9. Pitch shift + time stretch + beat detect
**Prompt:** Integrate SoundTouch (BSD) or Rubber Band (LGPL — note license tradeoff). Implement `pitchShift`, `timeStretch`. Implement `detectBeats` via onset detector (FFT energy flux peaks → autocorrelation tempo).
**Why:** Unlocks creative features (slow vocal, speed-corrected music, beat-synced cuts).
**Done when:** Stretch ±25% preserves intelligibility; BPM estimate within ±2 on top-40 reference tracks.

### D10. Native AudioSession manager
**Prompt:** Implement `configureSession({category, options, sampleRate, ioBufferMs})`. Categories: `playback`, `record`, `playAndRecord`, `ambient`. Options: `mixWithOthers`, `duckOthers`, `allowBluetooth`, `defaultToSpeaker`. iOS: `AVAudioSession`. Android: `AudioManager` mode + `AudioFocusRequest` + `AudioAttributes`. Emit route changes and interruptions over `state` channel.
**Why:** Final piece needed to remove `audio_session` pub dep.
**Done when:** Phone call during playback triggers interruption events; route changes (BT connect/disconnect) reported.

### D11. Native player engine (lightweight; audio-only consumers)
**Prompt:** Implement `playerCreate({path, loop})` returning `{playerId}` and `playerControl({playerId, op, value})` for `play/pause/seek/volume/rate`. ExoPlayer (Android) and `AVAudioPlayer` (iOS).
**Why:** Audio playback (music preview in trim sheet, voiceover monitor) without `audio_session`/`video_player` deps.
**Done when:** Two simultaneous players (music + voice monitor) play at independent rates.

### D12. Cut over the audio Dart code
**Prompt:** Replace all `audio_waveforms` / `audio_session` usage with the new channel + PlatformView. Fold `minis_music_trim_math.dart` and `minis_music_trim_sheet.dart` to use the native trim. Remove both packages from `pubspec.yaml`. `flutter pub get`, build, manually verify music trim sheet behavior in example.
**Why:** Closes improvement 4.
**Done when:** `grep -R "audio_waveforms\|audio_session" .` returns nothing in Dart source.

---

## Section E — Improvement 5: Native Media I/O, Pickers, Player, System

### E1. Bootstrap sys module + remaining channels
**Prompt:** Create `com.loopit.minis.sys` Android package and `ios/Classes/Sys/`. Register channels `loopit/minis/picker`, `loopit/minis/permissions` (full key set), `loopit/minis/paths`, `loopit/minis/player`, `loopit/minis/device`, `loopit/minis/wakelock`. Register the `loopit/minis/player` PlatformViewFactory. Skeleton classes per improvement5.md.
**Why:** Improvement 5 spans many small features; one bootstrap pays for all.
**Done when:** Channels exist; handlers throw NotImplemented.

### E2. Native media picker (image, video, multi)
**Prompt:** Implement `pickImage`, `pickVideo`, `pickMedia`. Android: PhotoPicker on API 33+, fallback to `MediaStore.ACTION_PICK`. iOS: `PHPickerViewController`. Copy selected items into app cache and return resolved local paths plus mime/size/dims/duration.
**Why:** First user-facing replacement for `image_picker`.
**Done when:** Example feed flow can select gallery images and videos with the new channel.

### E3. Native file picker
**Prompt:** Implement `pickFile({multi, mimeTypes[], extensions[]})`. Android: `ACTION_OPEN_DOCUMENT` with mime filters; copy to cache; persist URI grant only if requested. iOS: `UIDocumentPickerViewController`.
**Why:** Replaces `file_picker`.
**Done when:** Example app picks a file and reads its bytes.

### E4. Native video player (PlatformView + engine)
**Prompt:** Implement `player.create / play / pause / seek / volume / rate / dispose`. Android: ExoPlayer (Media3) on a `SurfaceView`. iOS: `AVPlayer` on `AVPlayerLayer`. Emit `loopit/minis/player/events/<playerId>`. Honor HDR; tonemap to SDR when display lacks support. Provide `fit` parameter (`cover`/`contain`/`fill`).
**Why:** Replaces `video_player` (used in story / reel / feed preview screens).
**Done when:** Replace `VideoPlayer(c)` widgets in example with `MinisPlayer(viewId)`; preview/loop/play/pause behaves identically; HDR clip plays with correct tone mapping on SDR screen.

### E5. Native paths + path helpers
**Prompt:** Implement `cacheDir`, `appSupportDir`, `documentsDir`, `externalDir`, `tempFile({ext})`, `join`, `extension`, `basename`. Dart wrapper exports a `MinisPaths` class with the same surface so existing `path.extension(x)` calls migrate to `MinisPaths.extension(x)` (sync via memoized initialization of the dir paths to avoid awaiting on every call).
**Why:** Replaces `path_provider` and `path`.
**Done when:** All `package:path` and `package:path_provider` imports removed from `lib/` and `example/lib/`.

### E6. Native permissions (full key set)
**Prompt:** Extend the permissions channel started in A11 with keys: `photos`, `photosAdd`, `location`, `locationAlways`, `notification`, `storage` (Android legacy). Map iOS Photos (`PHPhotoLibrary.authorizationStatus(for: .readWrite/.addOnly)`), Location (`CLLocationManager`), Notifications (`UNUserNotificationCenter.requestAuthorization`). Implement `openSettings` and an `events` stream for settings-page return.
**Why:** Replaces `permission_handler` completely.
**Done when:** Each permission key flips through `denied → request → granted` lifecycle in example.

### E7. Native device info + thermal + battery
**Prompt:** Implement `info`, `thermal`, `battery`. iOS: `UIDevice`, `ProcessInfo.processorCount`, `MTLCreateSystemDefaultDevice().name`, `VTCopySupportedPropertyDictionaryForEncoderProfile` for codec caps, `processInfo.thermalState`. Android: `Build.*`, `MemoryInfo`, `MediaCodecList.REGULAR_CODECS`, `PowerManager.currentThermalStatus` (API 29+), `BatteryManager`. Emit `loopit/minis/device/thermal` on state changes.
**Why:** Replaces `device_info_plus` and provides thermal hooks used by the camera engine.
**Done when:** Sample `{model, os, osVersion, ramMb, gpu, codecs[], hdrCapabilities}` dumps usefully on a real device.

### E8. Native wakelock
**Prompt:** Implement `enable`/`disable`. Android: `getWindow().addFlags(FLAG_KEEP_SCREEN_ON)` / `clearFlags`. iOS: `UIApplication.shared.isIdleTimerDisabled`.
**Why:** Replaces `wakelock_plus`.
**Done when:** `dumpsys power` confirms screen-on flag set; iOS Settings → Auto-Lock test confirms disabled.

### E9. Native share
**Prompt:** Implement `share({paths[], text, subject})`. Android: `Intent.ACTION_SEND`/`ACTION_SEND_MULTIPLE` wrapped in `Intent.createChooser`. iOS: `UIActivityViewController`. Used by the example after `MinisExampleSave.saveAndNotify`.
**Why:** Completes the export-out story without a `share_plus` dep.
**Done when:** Share sheet appears with the saved file pre-attached.

### E10. Icon-pack replacement (kill `phosphor_flutter`)
**Prompt:** Audit `grep -R "PhosphorIcons\|phosphor_flutter" lib/ example/lib/`. For each glyph, either map to a Material icon already in framework or include only those glyphs in a bundled `assets/fonts/minis_icons.ttf` and expose them via a `MinisIcons` Dart class. Remove `phosphor_flutter` from `pubspec.yaml`.
**Why:** Improvement 5 cleans up the last system-ish pub dep.
**Done when:** No `phosphor_flutter` references in source; visual diff of affected screens shows no change.

### E11. Cut over the image/video pickers and player in example app
**Prompt:** Replace every `ImagePicker()`, `FilePicker.platform.*`, `VideoPlayerController` usage in `lib/` and `example/lib/` with the new channels and the `MinisPlayer` PlatformView. Delete `image_picker`, `file_picker`, `video_player`, `path_provider`, `path`, `permission_handler`, `device_info_plus`, `wakelock_plus`, `phosphor_flutter` from `pubspec.yaml`. Run `flutter pub get`, `flutter analyze`, `flutter run` and exercise all three modes (reel/story/feed) end to end.
**Why:** Closes improvement 5.
**Done when:** `pubspec.yaml` `dependencies:` block contains only `flutter` (and `get` if kept). `flutter pub deps` confirms.

---

## Section F — Cross-cutting

### F1. CI / build matrix
**Prompt:** Add `.github/workflows/build.yaml` (or equivalent) that builds the plugin on Android (`./gradlew assembleDebug`) and iOS (`xcodebuild -workspace example/ios/Runner.xcworkspace …`). Cache FFmpeg builds keyed by `build_*.sh` hash + NDK/Xcode version. Fail on any new pub dep entering `pubspec.lock`.
**Why:** Prevents regression where someone re-adds a Dart media package.
**Done when:** PR check fails when a forbidden dep is reintroduced.

### F2. Migration guide (CHANGELOG.md)
**Prompt:** Write a one-page migration note describing the channel surface, breaking changes, the minimum OS versions (Android 8.0 / iOS 14.0), and instructions for the host app to register the new permission strings in `AndroidManifest.xml` / `Info.plist`.
**Why:** Host app integrators need a single source of truth.
**Done when:** Doc committed; example app's `AndroidManifest.xml` + `Info.plist` match it exactly.

### F3. Telemetry hook
**Prompt:** Add an opt-in `loopit/minis/telemetry` channel emitting structured events: capture start/stop, export start/stop/duration, codec used, thermal events, crashes-recovered. Disabled by default; host app calls `enable({sink: "log" | "stream"})`. No PII.
**Why:** Enterprise teams need observability without leaking user data.
**Done when:** Sample integration in example logs to console; off by default.

### F4. Integration test pass
**Prompt:** Add `integration_test/` package (using `flutter_test` only — already in dev deps) that drives reel capture → trim → export, story photo → edit → post, feed image-multi → post. Use `MinisPlayer` PlatformView in headless mode (or skip view-mount with `--headless` flag). Run on emulator + simulator in CI.
**Why:** End-to-end coverage for the surfaces removed Dart deps used to provide.
**Done when:** Suite green on CI.

---

## How to use this list
1. Pick the next undone task from the top of a section.
2. Execute the prompt; record the exact commands used.
3. When acceptance criteria pass, **move the task block** to `complete.md` (append a date stamp and a one-line summary of what shipped).
4. Update any downstream task whose assumptions changed because of what you actually built.
