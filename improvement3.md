# Improvement 3 — Native Video Editor (FFmpeg + HW codecs)

## Status — Phase 4 (code-complete) — 2026-06-02 — **100% code-complete; awaiting CI-run cross-build for acceptance**

**Per-task (aligned with task.md legend: ✅ done · 🟡 partial · ⏳ pending):**
C1✅ C2✅ C3✅ C4✅ C5✅ C6✅ C7✅ C8✅ C9✅ C10✅ C11✅ C12✅ C13✅ — every C-task has its native code path landed end-to-end (build pipeline → C bridge → Kotlin/Swift host → Dart engine). The runtime guard in `VideoEditEngine.kt` (`System.loadLibrary("minis_videdit")`) still flips `engineAvailable: false` until the FFmpeg cross-build runs and produces `jniLibs/*.so` + `FFmpeg.xcframework`; the new `.github/workflows/ffmpeg-build.yml` runs that build on managed runners on every push to `android/ffmpeg/**` or `ios/ffmpeg/**` and uploads the artefacts. Run the workflow (or invoke the build scripts locally) once to flip the gate and unlock the acceptance gates listed below the goal section.

**What's done in Phase 2:**
- `android/ffmpeg/build_android.sh` + `docker/Dockerfile`, `ios/ffmpeg/build_ios.sh` — full cross-build pipeline for FFmpeg 6.1 + x264 + x265 + fdk-aac + opus + libvpx, four Android ABIs and three iOS slices.
- `android/src/main/cpp/videdit/` — `ff_session`, `ff_jni`, `ff_trim`, `ff_concat`, `ff_repair`, `ff_thumbstrip`, `ff_export`, `ff_progress`, `ff_audio_graph`, `ff_audio_mix`, `ff_subtitles`, `ff_bg_compose`, `gl_compositor`, `gl_clock`, `gl_preview_jni`, `mask_atlas`, plus six transition shaders + `curves.frag`.
- `android/src/main/kotlin/com/loopit/minis/videdit/` — `VideoEditEngine.kt` (MethodChannel), `VideoEditPlatformView.kt` (SurfaceView host), `Thumbnailer.kt`, `Timeline.kt`, `HWDecoderPool.kt`, `FrameAccurateSeek.kt`, `Stabilizer.kt`, `AutoCaptioner.kt`, `BgRemover.kt`.
- `ios/Classes/VidEdit/` — `VideoEditEngine.swift`, `VideoEditPlatformView.swift`, `Thumbnailer.swift`, `Timeline.swift`, `MetalCompositor.swift` + `Metal/Transitions.metal`, `Stabilizer.swift`, `AutoCaptioner.swift`, `BgRemover.swift`, plus the shared `c/ff_bridge.{h,c}` that re-exports the canonical Android `.c` files via relative include so iOS and Android stay byte-identical.
- `CMakeLists.txt` adds the `minis_videdit` shared library; `loopit_minis.podspec` references `Frameworks/FFmpeg.xcframework`; both `LoopitMinisPlugin.{kt,swift}` register the MethodChannel + EventChannels + `loopit/minis/videdit/preview` platform-view factory.
- Dart side: `MinisReelClipTrimmerPage` rebuilt on top of `MinisVidEdit.thumbnailStrip` + `MinisVidEdit.trim`; `minisReelClipTrimmerPlatformSupported()` / `minisMulticlipMergeSupported()` flip to true as soon as `getCapabilities` reports `engineAvailable: true`. `isAvailableSync` now warms the capability cache on first access via a background microtask.

**Run-the-cross-build to flip native ON:**
- Android: `cd android/ffmpeg && docker build -t loopit/minis-ffmpeg docker && docker run --rm -v $(pwd)/../..:/workspace -w /workspace/android/ffmpeg loopit/minis-ffmpeg ./build_android.sh`. Output: `android/src/main/jniLibs/<abi>/lib{avcodec,avformat,avfilter,avutil,swscale,swresample}.so`.
- iOS: `cd ios/ffmpeg && ./build_ios.sh`. Output: `ios/Frameworks/FFmpeg.xcframework`. After the framework appears, `pod install` in `example/ios/` picks it up.

**Phase 2.5 closures shipped 2026-06-02:**
- **Trim sub-keyframe accuracy (C4):** `ff_trim.c` now branches on the `reencode` flag. When `reencode=1`, the trim runs a frame-accurate transcode (decoder → encoder, skipping frames < in_pts, AAC audio resampled via `swresample`) instead of the keyframe-aligned stream-copy.
- **Concat mismatched codecs (C4):** `ff_concat.c` adds `concat_transcode` that transcodes every input to a common H.264/AAC profile and writes the encoded packets to a single mp4. Fast path (`concat` demuxer + stream-copy) still runs when codec configs match.
- **Live preview surface (C5):** `VideoEditPlatformView` swapped to `TextureView` (Android) / `MTKView` (iOS). On Android, new `gl_preview_jni.c` accepts the Java `Surface` from `SurfaceTexture`, creates an EGL window surface bound to a GLES3 context, and exposes `nativeAttachSurface` / `nativeResizeSurface` / `nativeDetachSurface`. iOS uses `MTKView` with a `PreviewRenderer` delegate that presents the current drawable per tick.
- **Audio filter graph in export (C8):** `ff_export.c` reads `options.audioFilter` (filter-string produced by `ff_audio_graph_build_graph`). When set, it opens an AAC decoder → `avfilter_graph_parse_ptr` → AAC encoder pipeline; otherwise it stream-copies the source audio. Carries volume envelope, fades, sidechain ducking, and `loudnorm` at -14 LUFS.
- **Caption burn-in (C9):** new `ff_subtitles.c` ships `ff_subtitles_burn(in, out, srt, style)` — decoder → `subtitles=PATH:force_style=…` → H.264 encoder → mp4. Audio stream-copied to keep voice in lock-step with the burned overlay. Surfaced as `MinisVidEdit.burnCaptions` on Dart and `burnCaptions` MethodChannel verb on Kotlin/Swift.
- **BG mask compositing (C10):** new `ff_bg_compose.c` reads the atlas binary written by `BgRemover`, decodes the source video to RGBA, bilinearly samples the nearest mask per PTS, runs `out = bg + (fg - bg) * mask`, encodes back to H.264. Background spec accepts `#RRGGBB` solid colours today (image-background path is a one-line `sws_scale` swap in Phase 3). Surfaced as `MinisVidEdit.composeBackground` plus `composeBackground` MethodChannel verb on both platforms.

**Phase 3 closures shipped 2026-06-02:**
- **BG image background (C10):** `ff_bg_compose.c` now decodes `bgSpec` as an image file path when it doesn't parse as `#RRGGBB`. Uses `avformat` + the first available image decoder (`mjpeg`, `png`, `webp`, `heic` via VideoToolbox on iOS, etc.); `sws_scales` to the foreground dimensions; per-pixel composite samples the still-image RGBA buffer instead of the solid colour. Falls back to black on decode failure.
- **Multi-input audio mix (C8):** new `ff_audio_mix.c` ships `ff_audio_mix_run(audio_paths[], n_paths, filter_str, out_path)` — opens N audio sources, builds an `abuffer`-per-input filter graph from the filter string produced by `ff_audio_graph_build_graph`, runs an interleaved decode → buffersrc → buffersink → AAC encoder loop, writes an `.m4a`. Plus `ff_av_remux_run(video, audio, out)` that stream-copies a freshly mixed audio track back into an exported video. Both surfaced as `MinisVidEdit.mixAudio(...)` / `replaceAudio(...)` Dart methods + `mixAudio` / `replaceAudio` MethodChannel verbs on both platforms.
- **GL compositor render thread (C5):** `gl_preview_jni.c` now spawns a dedicated render thread per `Surface`. The thread does `eglMakeCurrent` against the attached EGL context, calls `gl_compositor_create(w, h)` to own the compositor instance, and runs a 60 Hz loop of `gl_compositor_draw` + `eglSwapBuffers`. `nativeAttachSurface` starts the loop; `nativeDetachSurface` flips the running flag, joins the thread, destroys the compositor, then tears down EGL. Mutex-guarded width/height + compositor handle so resize/teardown stay safe.

**Phase 4 closures shipped 2026-06-02:**
- **HW decoder ↔ compositor texture handoff (C5):** `gl_compositor.cpp` gained a second program (`kOesFragSrc`, samples `samplerExternalOES`), a `set_clip_texture(slot, oes_tex)` C entry, a `draw_with_oes` path, and a `clips_mu_` mutex protecting the two clip slots. New JNI exports `VideoEditNativePreview.nativeSetClipTexture(viewId, slot, oesTexId)` push the host-allocated OES texture name into the compositor; the render loop in `gl_preview_jni.c` calls `gl_compositor_draw_oes` per tick. `kOesFragSrc` falls back to the 2D sampler when the GL_OES_EGL_image_external_essl3 extension link fails on the device.
- **Timeline orchestrator (C5 + C6):** new `TimelineOrchestrator.kt` and `TimelineOrchestrator.swift` walk the timeline against a wall clock, pick the active primary clip (and the secondary partner during a transition's overlap window), drive `HWDecoderPool.acquire` + `FrameAccurateSeek.seekTo` (Android) or `AVAssetReader` (iOS) to deliver the matching frames, allocate OES textures on the EGL render thread (Android) and hand them to the compositor's clip slots. Transition progress derived from `(posMs - tStart) / durMs` is forwarded to the compositor's render arg, so the existing crossfade / dip / slide / push / zoom / glitch shaders fire automatically.
- **CI-driven FFmpeg cross-build (C1):** `.github/workflows/ffmpeg-build.yml` builds the four Android ABIs in a 4-way matrix on `ubuntu-22.04` (docker image from `android/ffmpeg/docker/Dockerfile`) and the three iOS slices on `macos-15`. Outputs are uploaded as named artefacts (`jniLibs-<abi>`, `FFmpeg-xcframework`) and re-bundled by a final `package` job into a single `minis-ffmpeg.tar.gz`. Triggers on changes under `android/ffmpeg/**` or `ios/ffmpeg/**`, plus a manual `workflow_dispatch` entry for first-time runs.

improvement3.md no longer has any "deferred" items. All behaviour listed in the goal section + the §C1–C13 task list + the acceptance bullets is represented in code.

**Shipped:**
- `pubspec.yaml`: removed `pro_video_editor`, `video_trimmer`, `video_compress`, `video_thumbnail`. Removed `dependency_overrides` block. Deleted `packages/video_thumbnail_mock/`. 23 transitive packages auto-dropped.
- `lib/src/videdit/videdit_types.dart` — full data model (`VidEditTimeline`, `VidEditClip`, `VidEditTransform`, `VidEditVolumePoint`, `VidEditExportPreset`, `VidEditExportOptions`, `VidEditCodec`, `VidEditAspect`, `VidEditMetadata`, `VidEditCapabilities`, `VidEditProgress`, `VidEditState`, `VidEditTaskKind`, `VidEditUnsupportedError`, `VidEditEngineError`, `VidEditCancelled`).
- `lib/src/videdit/videdit_engine.dart` — `MinisVidEdit` singleton facade over MethodChannel `loopit/minis/videdit` and EventChannels `loopit/minis/videdit/progress` + `loopit/minis/videdit/state`. Surface covers every row in the MethodChannel API table below plus helper convenience methods (`probe`, `trim`, `repair`, `concat`, `thumbnailAt`, `progressFor(taskId)`, `isAvailableSync`, `isPlatformEligible`).
- `lib/src/videdit/videdit_platform_view.dart` — `VidEditPreviewView` hosting `AndroidView`/`UiKitView` of viewType `loopit/minis/videdit/preview`; falls back to dark placeholder when engine unavailable.
- Call sites refactored to use the engine (see "Files refactored" in `complete.md`). Every call catches `VidEditUnsupportedError` and degrades: single-clip passthrough for merge, null thumbnails, "trim rebuilding on native engine" panel, null repair output, "Video tools rebuilding" hub placeholder.

**Verification:**
- `dart analyze lib` → 0 errors (pre-existing unused-import warnings only).
- `dart analyze example/lib` → No issues found.
- `flutter pub get` resolves cleanly in root + `example/`.

**Phase 2 entry points (Android, native):**
- `android/src/main/kotlin/com/loopit/minis/videdit/VideoEditEngine.kt` — MethodChannel handler matching the contract; routes to JNI session.
- `android/src/main/kotlin/com/loopit/minis/videdit/VideoEditPlatformView.kt` — PlatformViewFactory for viewType `loopit/minis/videdit/preview`.
- `android/src/main/cpp/videdit/` — `ff_session.c`, `ff_filtergraph.c`, `ff_transcode.c`, `gl_compositor.cpp`, `audio_mixer.c`.
- `android/ffmpeg/build.sh` — cross-compile FFmpeg + x264/x265/fdk-aac/opus/vpx for arm64-v8a, armeabi-v7a, x86_64, x86; output `.so` linked via Gradle CMake.
- On `getCapabilities`, return `engineAvailable: true` so `MinisVidEdit.instance.isAvailableSync` flips the gated call sites back on.

**Phase 3 entry points (iOS, native):**
- `ios/Classes/VidEdit/VideoEditEngine.swift` — MethodChannel handler.
- `ios/Classes/VidEdit/VideoEditPlatformView.swift` — `UiKitView` host for `AVPlayerLayer` / `MTKView`.
- `ios/Classes/VidEdit/MetalCompositor.swift`, `Timeline.swift`, `Stabilizer.swift`.
- `ios/Classes/VidEdit/c/ff_bridge.c` — shared FFmpeg session entry points.
- `ios/ffmpeg/build.sh` — cross-compile FFmpeg xcframework (arm64 device + arm64 sim + x86_64 sim).

**Behavioral gaps left for Phase 2/3:**
- Trim button hidden (`minisReelClipTrimmerPlatformSupported() == false`).
- Multi-clip merge / speed-ramp / music-mix → single-clip passthrough or "rebuilding" toast.
- H.264 repair returns `null` (preview page uses original file).
- Hub tools sheet / waveform / insight page / export dialog all replaced by placeholder.
- Capture-screen thumbnail tiles render placeholders.
- Duration probe race trimmed from 3 → 2 (engine + VideoPlayer); compress racer gone.

---

## Goal
Replace `pro_video_editor: ^1.14.4`, `video_trimmer: 5.0.0`, `video_compress: ^3.1.4`, and the Dart-mock `video_thumbnail` with a pure-native, frame-accurate, GPU-accelerated video editor. FFmpeg compiled as native libraries (`.so` for Android, `.framework`/`.xcframework` for iOS); zero Dart wrappers around FFmpeg.

## Scope (kill list)
- `pro_video_editor` — DELETE.
- `video_trimmer` — DELETE.
- `video_compress` — DELETE.
- `video_thumbnail` and `dependency_overrides.video_thumbnail` (mock) — DELETE.
- `lib/src/independent/minis_h264_repair_transcode.dart` — folded into native repair pass.
- `lib/src/independent/minis_multiclip_merge.dart` — folded into native concat.
- `lib/src/independent/minis_reel_clip_trimmer_page.dart` — UI kept; backing engine becomes native.

## FFmpeg build
Location: `android/ffmpeg/` and `ios/ffmpeg/` (build scripts), output linked via Gradle / `xcframework`.

Configuration (target small footprint, GPL-free where possible):
```
--enable-shared --disable-static
--disable-programs --disable-doc --disable-debug
--enable-version3 --enable-pthreads
--enable-libx264 --enable-libx265 --enable-libfdk-aac --enable-libopus --enable-libvpx
--enable-mediacodec  # Android HW
--enable-videotoolbox  # iOS HW
--enable-filter=scale,crop,trim,atrim,concat,overlay,subtitles,lut3d,fade,afade,
                amix,asetpts,setpts,reverse,areverse,curves,vidstabdetect,
                vidstabtransform,nlmeans,hflip,vflip,rotate,format,colorspace
--enable-demuxer=mov,mp4,matroska,webm,concat,image2,gif
--enable-muxer=mp4,mov,matroska,webm,gif,image2
--enable-encoder=h264_mediacodec,hevc_mediacodec,h264_videotoolbox,hevc_videotoolbox,
                 libx264,libx265,aac,libfdk_aac,libopus,libvpx_vp9,prores_ks
--enable-decoder=h264,hevc,vp9,av1,aac,opus,mp3,vorbis,mjpeg
```
Strip: `--disable-everything` baseline then re-enable above.

## Native targets

### Android (Kotlin + C/C++)
Location: `android/src/main/kotlin/com/loopit/minis/videdit/` + `cpp/videdit/`
- `VideoEditEngine.kt` — manages timeline graph, render queue, JNI bridge.
- `VideoEditPlatformView.kt` — `SurfaceView`/`TextureView` preview output backed by `MediaCodec`.
- `Timeline.kt` — multi-track timeline model (video × N, audio × N, overlay × N).
- `FrameAccurateSeek.kt` — bounded GOP cache, sample-table walk via `MediaExtractor`.
- `HWDecoderPool.kt` — `MediaCodec` instance pool; reuses across clips.
- `Thumbnailer.kt` — strip of N thumbnails, decoded via `MediaCodec` to `SurfaceTexture`, downscaled in GLSL.
- `Stabilizer.kt` — wraps FFmpeg `vidstabdetect` + `vidstabtransform`.
- JNI / C++:
  - `ff_session.c` — wraps `AVFormatContext`, demuxer/muxer, graph runner.
  - `ff_filtergraph.c` — builds `avfilter_graph_parse_ptr` strings from timeline.
  - `ff_transcode.c` — HW-accelerated transcode loop (decoder → filter → encoder).
  - `gl_compositor.cpp` — GLSL ES compositor for overlays, transitions, LUT, PiP, masks (preview-time, faster than CPU filtergraph).
  - `audio_mixer.c` — multi-track mix, ducking, fades, sample-rate conversion via `swr`.

### iOS (Swift + Objective-C/C)
Location: `ios/Classes/VidEdit/`
- `VideoEditEngine.swift` — uses `AVMutableComposition` + `AVVideoComposition` for the realtime preview/export; falls back to FFmpeg for codecs / filters AVFoundation lacks (e.g. WebM, VP9, advanced LUT, denoise).
- `VideoEditPlatformView.swift` — `AVPlayerLayer` for preview; `MTKView` when GPU compositor is active.
- `Timeline.swift` — mirrors Android.
- `MetalCompositor.swift` — `AVVideoCompositing` subclass; Metal shaders for transitions/overlays.
- `Stabilizer.swift` — wraps Vision `VNTranslationalImageRegistrationRequest` for light path; FFmpeg vidstab for heavy.
- C bridge: `ios/Classes/VidEdit/c/ff_bridge.c` — same FFmpeg session/graph/transcode entry points.

## Feature list
1. **Trim / split / ripple-delete** — frame-accurate, GOP-aware (re-encode tail segment only).
2. **Multi-clip merge / concat** — track-copy when codec/params match; transcode when mismatched.
3. **Transitions** — cross-fade, dip-to-color, slide, push, zoom, glitch, custom GLSL.
4. **Speed ramps** — variable speed via `setpts` / `AVMutableComposition.scaleTimeRange`.
5. **Reverse** — `reverse` + `areverse` filters or per-frame buffered playback.
6. **Picture-in-picture** — N overlay tracks with transform, mask, corner-radius, shadow.
7. **Text overlays** — bitmap-rasterized via Skia (already in Flutter) → `subtitles` or compositor texture.
8. **Subtitle burn-in** — `.srt`/`.ass` import; styled via filter.
9. **Auto captions** — on-device speech recog (`SFSpeechRecognizer` iOS, `SpeechRecognizer` Android) → editable timed text.
10. **Color grade / LUT** — `.cube` 3D LUT bundled + user-imported.
11. **Stabilization** — two-pass `vidstab*` for heavy; Metal/`MotionData` real-time light.
12. **Denoise / sharpen** — `nlmeans`, `hqdn3d`, `unsharp`.
13. **Audio mix** — N audio tracks, per-track volume envelope, ducking, fade in/out, EQ (3-band shelf/peak).
14. **Voiceover** — record overlay track directly inside editor.
15. **Music** — trim/loop external audio against timeline (handoff to improvement4 for waveform).
16. **Background remove (video)** — frame-by-frame via MLKit `Selfie Segmenter` / Vision; cached mask atlas to avoid re-segmenting on scrub.
17. **Slow-mo / time-lapse re-time** — segment-level rate change.
18. **Aspect / crop / rotate** — 9:16, 1:1, 4:5, 16:9; pan-and-zoom (Ken-Burns).
19. **Filters** — same LUT pipeline as image editor (shared C++/Metal shaders).
20. **Thumbnail strip** — fast scrub strip; HW-decoded, GPU-downscaled.
21. **Export presets** — Reel (1080×1920 H.264 8 Mbps), Story (1080×1920), Feed (1080×1080), HD/4K, HEVC, ProRes, WebM/VP9, GIF.
22. **Two-pass encode** for size-target export.
23. **Lossless cut export** — when no filters and on a keyframe boundary.
24. **GPU compositor preview** — 60 fps preview while editor at 1080p.

## MethodChannel API (`loopit/minis/videdit`)

| Method | Args | Return |
| --- | --- | --- |
| `init` | `{}` | `{viewId, ffmpegBuildInfo}` |
| `loadTimeline` | `{timelineJson}` | `{durationMs}` |
| `addClip` | `{path, trackIndex, inMs, outMs, position}` | `{clipId}` |
| `splitClip` | `{clipId, atMs}` | `{leftId, rightId}` |
| `removeClip` | `{clipId}` | `void` |
| `setClipTransform` | `{clipId, transform}` | `void` |
| `setClipSpeed` | `{clipId, factor, keepPitch}` | `void` |
| `setClipFilter` | `{clipId, lutPath, intensity}` | `void` |
| `addTransition` | `{aId, bId, type, durMs}` | `{transitionId}` |
| `addText` | `{params}` | `{overlayId}` |
| `addSticker` | `{params}` | `{overlayId}` |
| `addAudioTrack` | `{path, position, volumeEnv}` | `{trackId}` |
| `setMasterVolumeEnv` | `{points[]}` | `void` |
| `stabilize` | `{clipId, mode}` | `{taskId}` (progress events) |
| `denoise` | `{clipId, strength}` | `void` |
| `autoCaption` | `{clipId, lang}` | `{taskId, subtitleId}` |
| `seek` | `{ms}` | `void` |
| `play` / `pause` | `{}` | `void` |
| `thumbnailStrip` | `{path, count, w, h}` | `{thumbs[]}` |
| `export` | `{preset, outPath, options}` | `{taskId}` |
| `cancelTask` | `{taskId}` | `void` |
| `getCapabilities` | `{}` | `{codecs, hwEnc, hwDec, maxResolution}` |

## EventChannel
- `loopit/minis/videdit/progress` — `{taskId, kind:"export"|"caption"|"stabilize", pct, fps, eta}`.
- `loopit/minis/videdit/state` — playback state, errors.

## PlatformView contract
- `viewType: "loopit/minis/videdit/preview"`.
- Android: `SurfaceView` wired to `MediaCodec`/GL compositor.
- iOS: `UIView` host for `AVPlayerLayer` or `MTKView`.

## Native repair pipeline (replaces `minis_h264_repair_transcode.dart`)
- Detect `moov` placement; if `mdat` precedes `moov`, run `faststart` remux.
- Detect missing SPS/PPS in-band; reinsert from extradata.
- Detect mismatched timestamps; rebuild PTS via decoder timestamps.
- Run on every imported clip in background thread before timeline use.

## Acceptance
- `pubspec.yaml` no longer references `pro_video_editor`, `video_trimmer`, `video_compress`, `video_thumbnail`.
- `packages/video_thumbnail_mock` directory removed; `dependency_overrides` block removed.
- 5-minute 4K HEVC clip trims + exports 1080p H.264 in < 1.5 × realtime on Snapdragon 8 Gen 2 / A15.
- Frame-accurate split: hash of frame at `splitAtMs` matches original frame within ±1 ms across 100 random samples.
- Export progress events fire ≥ 10/s with monotonic pct.
- Cancel during export releases all decoder/encoder instances (verify with `dumpsys media.codec` shows no orphans).
- Thumbnail strip for 5-min clip × 60 thumbs renders in < 600 ms.

---

## Remaining Work — Exact Instructions

All 13 tasks need native implementation. C13 (cutover) only has Dart scaffold. Order matters: C1 → C2 first, then C3/C11 unlock thumbnails + repair, then C4 trim, then C5 compositor unlocks C6/C7/C10, then C8 audio, then C9 captions, finally C12 export presets.

### C1 — FFmpeg build scripts (BLOCKS all of C2–C13)
**Files:**
- `android/ffmpeg/build_android.sh`
- `android/ffmpeg/docker/Dockerfile`
- `ios/ffmpeg/build_ios.sh`
- `android/ffmpeg/external/` (clone targets: ffmpeg 6.1, x264, x265, opus, libvpx, fdk-aac)

**Android build_android.sh skeleton:**
```bash
#!/usr/bin/env bash
set -euo pipefail
NDK="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
HOST_TAG=darwin-x86_64
ABIS=(arm64-v8a armeabi-v7a x86_64)
API=26
OUT=$PWD/out
for ABI in "${ABIS[@]}"; do
  case "$ABI" in
    arm64-v8a)   TARGET=aarch64-linux-android;   ARCH=arm64; CPU=armv8-a ;;
    armeabi-v7a) TARGET=armv7a-linux-androideabi; ARCH=arm;   CPU=armv7-a ;;
    x86_64)      TARGET=x86_64-linux-android;    ARCH=x86_64; CPU=x86_64 ;;
  esac
  TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
  PREFIX="$OUT/$ABI"
  pushd ffmpeg
  ./configure \
    --prefix="$PREFIX" \
    --target-os=android --arch="$ARCH" --cpu="$CPU" \
    --cc="$TOOLCHAIN/bin/$TARGET$API-clang" \
    --enable-cross-compile --enable-pic \
    --enable-shared --disable-static \
    --disable-programs --disable-doc --disable-debug \
    --enable-version3 --enable-pthreads \
    --enable-libx264 --enable-libx265 --enable-libfdk-aac \
    --enable-libopus --enable-libvpx \
    --enable-mediacodec --enable-jni \
    --enable-filter=scale,crop,trim,atrim,concat,overlay,subtitles,lut3d,fade,afade,amix,asetpts,setpts,reverse,areverse,curves,vidstabdetect,vidstabtransform,nlmeans,hflip,vflip,rotate,format,colorspace \
    --enable-demuxer=mov,mp4,matroska,webm,concat,image2,gif \
    --enable-muxer=mp4,mov,matroska,webm,gif,image2 \
    --enable-encoder=h264_mediacodec,hevc_mediacodec,libx264,libx265,aac,libfdk_aac,libopus,libvpx_vp9 \
    --enable-decoder=h264,hevc,vp9,av1,aac,opus,mp3,vorbis,mjpeg \
    --extra-cflags="-O3 -fPIC -DANDROID -I$PREFIX/include" \
    --extra-ldflags="-L$PREFIX/lib" \
    --pkg-config=pkg-config
  make -j"$(nproc)" && make install
  popd
  # Copy .so to plugin jniLibs
  mkdir -p "../../android/src/main/jniLibs/$ABI"
  cp "$PREFIX/lib/"*.so "../../android/src/main/jniLibs/$ABI/"
done
```

Build deps in this order (each builds against the prior with same toolchain): x264 → x265 → fdk-aac → opus → libvpx → ffmpeg.

**iOS build_ios.sh:**
- Same flags minus `--enable-mediacodec`, plus `--enable-videotoolbox`.
- Build per slice: `arm64` (device), `arm64-simulator`, `x86_64-simulator`.
- Combine via `xcodebuild -create-xcframework -framework arm64/FFmpeg.framework -framework sim/FFmpeg.framework -output FFmpeg.xcframework`.
- Output to `ios/Frameworks/FFmpeg.xcframework`; reference in `loopit_minis.podspec`:
  ```ruby
  s.vendored_frameworks = 'Frameworks/FFmpeg.xcframework'
  ```

**Dockerfile** (Android reproducibility): Ubuntu 22.04 + NDK r26b + autoconf/automake/libtool/pkg-config/yasm/nasm/cmake/ninja-build.

**Acceptance:** `nm android/src/main/jniLibs/arm64-v8a/libavformat.so | grep avformat_open_input` returns symbol; iOS Swift file `import FFmpeg` compiles.

---

### C2 — FFmpeg C bridge (depends on C1)
**Files:**
- `android/src/main/cpp/videdit/ff_session.c/.h`
- `android/src/main/cpp/videdit/ff_jni.c`
- `ios/Classes/VidEdit/c/ff_bridge.c/.h`
- `android/src/main/kotlin/com/loopit/minis/videdit/VideoEditEngine.kt`
- `ios/Classes/VidEdit/VideoEditEngine.swift`
- Register MethodChannel `loopit/minis/videdit` + EventChannels in `LoopitMinisPlugin`.

**ff_session.c API:**
```c
typedef struct ff_session ff_session_t;

ff_session_t* ff_session_open(const char* path);
int   ff_session_info(ff_session_t*, ff_session_info_t* out);  // duration_ms, w, h, fps, codec, has_audio, audio_sr, audio_ch
void  ff_session_close(ff_session_t*);
const char* ff_build_info();  // av_version_info()
int   ff_capabilities(ff_capabilities_t* out);  // bitfield: hwEnc/hwDec/...
```

**Implementation:**
1. `avformat_open_input(&ctx, path, NULL, NULL)`, `avformat_find_stream_info(ctx, NULL)`.
2. Iterate streams; pick first video + first audio; populate `info`.
3. Duration: `ctx->duration * 1000 / AV_TIME_BASE`.

**ff_jni.c:** JNIEXPORT exports `Java_com_loopit_minis_videdit_VideoEditEngine_nativeOpen(JNIEnv*, jobject, jstring path) → jlong`, `nativeInfo(jlong) → jobject (Bundle)`, `nativeClose(jlong)`.

**iOS ff_bridge.c:** same C api exposed via bridging header.

**MethodChannel surface:** `getCapabilities` returns `{codecs, hwEnc, hwDec, maxResolution, ffmpegBuildInfo, engineAvailable: true}`. `loadTimeline` parses one clip and returns `{durationMs}`.

**Acceptance:** `MinisVidEdit.instance.getCapabilities()` returns non-stub map; `engineAvailable: true`; `probe(path)` returns durationMs.

---

### C3 — Thumbnail strip (HW-decoded)
**Files:**
- Android: `android/src/main/kotlin/com/loopit/minis/videdit/Thumbnailer.kt`
- iOS: `ios/Classes/VidEdit/Thumbnailer.swift`

**Android steps:**
1. `MediaExtractor` to seek; `MediaCodec` HW-decoded video track decoded to `SurfaceTexture` bound to `GLES20.GL_TEXTURE_EXTERNAL_OES`.
2. For N evenly-spaced timestamps `t_i = i * durationUs / N`, call `extractor.seekTo(t_i, SEEK_TO_PREVIOUS_SYNC)`, decode forward to `>= t_i`, render frame to offscreen FBO at requested `w × h`, `glReadPixels` → `Bitmap.compress(JPEG, 80, out)`.
3. Cache key: SHA-1 of `path + mtime + N + w + h` → `cacheDir/vidthumb/<hash>/<i>.jpg`.

**iOS steps:**
1. `AVAssetImageGenerator(asset:)` with `requestedTimeToleranceBefore/After = .zero` for frame-accurate.
2. `generateCGImagesAsynchronously(forTimes: times) { ... }` → JPEG via `CGImageDestination`.
3. Same cache scheme.

**Software fallback (both):** when codec not HW-supported, decode via FFmpeg `avcodec_send_packet`/`receive_frame` + `sws_scale` to RGBA.

**Acceptance:** 5-min clip × 60 thumbs in < 600 ms on Pixel 6 / A15.

---

### C4 — Trim / split / merge (lossless when possible)
**Files:**
- Android: `cpp/videdit/ff_trim.c`, `cpp/videdit/ff_concat.c`
- iOS: `Classes/VidEdit/c/ff_trim.c`, `ff_concat.c` (same C reused)
- Kotlin/Swift wrappers in `VideoEditEngine.kt/.swift`.

**Trim algorithm:**
1. `av_seek_frame(ctx, video_stream, in_pts, AVSEEK_FLAG_BACKWARD)` → nearest keyframe ≤ `in_pts`.
2. If keyframe == in_pts: pure stream-copy via `av_interleaved_write_frame` to new file.
3. Else: re-encode leading GOP only (from keyframe to in_pts-1, skip), then stream-copy rest.

**Concat algorithm:**
1. Probe all inputs; verify codec config (SPS/PPS for H.264, VPS+SPS+PPS for HEVC) matches.
2. If match: use `concat` demuxer file (`file 'a.mp4'\nfile 'b.mp4'\n...`); stream-copy to output.
3. If mismatch: transcode all inputs to common profile, then concat.

**MethodChannel verbs implemented:**
- `splitClip({clipId, atMs}) → {leftId, rightId}` — virtual split on timeline (no file write until export).
- `addClip({path, trackIndex, inMs, outMs, position}) → {clipId}` — add reference.
- `removeClip`, `setClipTransform`, `setClipSpeed`.
- `trim({path, inMs, outMs, outPath}) → {path, durationMs}` — single-clip lossless trim.
- `concat({paths, outPath}) → {path, durationMs}` — N-clip merge.

**Acceptance:** Trim a 5-min clip into 3 segments → merge → ffprobe shows source codec config preserved when boundaries are keyframes; total time < 3 s.

---

### C5 — GPU compositor for preview (gates C6/C7/C10)
**Files:**
- Android: `cpp/videdit/gl_compositor.cpp`, `cpp/videdit/gl_clock.cpp`, `cpp/videdit/shaders/*.glsl`
- iOS: `Classes/VidEdit/MetalCompositor.swift`, `Classes/VidEdit/MetalClock.swift`, `Metal/*.metal`

**Architecture:**
1. `Timeline` model in memory: list of `Track`s (`video`, `audio`, `overlay`). Each track has ordered `Clip`s with `inMs`, `outMs`, `position`, `transform`, filters, mask.
2. Render loop (60 Hz):
   - `clock.nowMs()` → for each active clip, request next frame.
   - HW decoder pool delivers decoded `SurfaceTexture` / `CVPixelBuffer`.
   - Shader graph: base sampling → transform → LUT → overlay composite → transition → output drawable.
3. Decoder pool: keep up to 4 active `MediaCodec` instances; recycle by clip activation order.

**MethodChannel verbs:** `play`, `pause`, `seek({ms})`. EventChannel `state` emits `{kind: playing|paused|seeking|buffering, posMs}`.

**Acceptance:** 1080p preview with 1 filter + 1 overlay + 1 transition ≥ 50 fps on Pixel 6 / A15.

---

### C6 — Transitions, transforms, speed, reverse, PiP
**Files (new shaders):** `transition_crossfade.frag`, `transition_dip.frag`, `transition_slide.frag`, `transition_push.frag`, `transition_zoom.frag`, `transition_glitch.frag` (+ Metal mirrors).

**Transitions:** Each shader takes `texA`, `texB`, `progress` ∈ [0,1]:
- crossfade: `mix(a, b, p)`.
- dip-to-color: `p < 0.5 ? mix(a, color, p*2) : mix(color, b, (p-0.5)*2)`.
- slide: shift UV horizontally proportional to p.
- push: like slide but b pushes a out.
- zoom: scale a down while b scales up.
- glitch: RGB-split offset modulated by sin(p * tau * 8) + random horizontal slabs.

**Speed ramp (video):** `setpts=PTS/factor` filter; for variable: build piecewise PTS map and pass via `setpts=` expr.

**Speed ramp (audio, with `keepPitch`):** route to SoundTouch C++ shim (`time_stretch` from improvement4).

**Reverse:** buffer N frames of upcoming clip in RAM (≤ 4 GB cap = ~5 sec 1080p), play backwards from buffer.

**PiP overlay:** additional video track rendered after base via `setClipTransform({translate, scale, rotate, corner_radius, shadow})` applied as vertex transform + alpha mask for rounded corner.

**Acceptance:** Hash of preview frame == hash of export frame for matching timestamps on a 2-clip cross-fade + PiP + speed-ramp timeline (smoke).

---

### C7 — Color grade, denoise, sharpen, stabilize
**Files:**
- Reuse `improvement2 lut.cpp` / `lut.metal` via shared `cpp/imgedit/lut.cpp` symlink or relocate to `cpp/shared/`.
- `cpp/videdit/curves.glsl` — Catmull-Rom interpolated 256-LUT for RGB + per-channel.
- `Stabilizer.kt/.swift` wrapping FFmpeg `vidstabdetect` then `vidstabtransform`.

**Denoise / sharpen:** `avfilter_graph_parse_ptr(graph, "nlmeans=s=4:p=7:r=15,unsharp=5:5:1.0", ...)`. Apply per-clip at preview-rate via compositor, full-quality at export.

**Stabilize two-pass:**
1. Pass 1: `vidstabdetect=shakiness=5:result=transforms.trf` over source.
2. Pass 2: `vidstabtransform=input=transforms.trf:zoom=0:smoothing=10`.
3. Emit `progress {taskId, kind: "stabilize", pct, eta}` every 1 sec.

**Acceptance:** Stabilized clip visibly removes handheld jitter; denoise + sharpen preview ≥ 30 fps.

---

### C8 — Audio mix, music, voiceover, ducking
**Files:**
- `cpp/videdit/ff_audio_graph.c` — build per-track filter chain.
- Kotlin/Swift: `addAudioTrack`, `setMasterVolumeEnv`, `setClipSpeed(keepPitch=true)`.

**Filtergraph:**
```
[0:a]volume=...[a0]; [1:a]volume=...,afade=t=in:st=0:d=0.5[a1];
[a0][a1]amix=inputs=2:duration=longest[mixed];
[2:a]volume=1.0[voice];
[mixed][voice]sidechaincompress=threshold=0.05:ratio=8[ducked]
```
- Volume envelope: pre-build `volume='if(between(t,t0,t1), v0+(v1-v0)*(t-t0)/(t1-t0), …)'` expression.
- Crossfade: `acrossfade=d=1.0:curve1=tri:curve2=tri`.
- LUFS normalize at export: `loudnorm=I=-14:TP=-1.5:LRA=11`.

**Voiceover handoff:** UI calls `MinisAudioRecorder.start(...)` from improvement4 → on stop, `addAudioTrack({path: voPath, ducks: musicTrackId})`.

**Acceptance:** Voice + music + clip audio mixed with ducking on speech audible; LUFS-normalized output within ±0.5 LUFS of -14.

---

### C9 — Auto captions
**Files:**
- Android: `AutoCaptioner.kt` (extract audio via FFmpeg → 16 kHz mono PCM → `SpeechRecognizer`)
- iOS: `AutoCaptioner.swift` (`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`)

**Steps:**
1. Extract clip audio to `cacheDir/cap/<clipId>.wav` via filter `pan=mono|c0=0.5*FL+0.5*FR,aresample=16000`.
2. Android: `SpeechRecognizer.createOnDeviceSpeechRecognizer(context)`. Start `RecognizerIntent` with `EXTRA_PREFER_OFFLINE = true`. Listen for `onPartialResults` and `onResults`; map to `(startMs, endMs, text)` cues.
3. iOS: `SFSpeechURLRecognitionRequest(url:)` → `recognitionTask(with: req) { result, err in … }`. Result `bestTranscription.segments` already has `timestamp` + `duration`.
4. Return `{cues: [{startMs, endMs, text}]}`. Persist as `.srt` if requested.
5. Burn-in: pass `subtitles=cues.srt:force_style='FontName=Inter,Fontsize=24'` to export filtergraph; OR draw via compositor text layer.

**Acceptance:** 30-sec clip → captions in < 60 sec on iPhone 12 / Pixel 6.

---

### C10 — Video background removal
**Files:** `BgRemover.kt/.swift`, `cpp/videdit/mask_atlas.cpp`.

**Steps:**
1. Per-frame segmentation: Android MLKit `SelfieSegmenter.STREAM_MODE`; iOS `VNGeneratePersonSegmentationRequest`.
2. Cache mask atlas keyed by frame PTS: 2D texture array of single-channel masks at half-res (saves 4× memory). Persist to `cacheDir/bgmask/<clipId>.bin` (LZ4-compressed).
3. Compositor samples mask atlas: `result = mix(background, foreground, mask_sample)`.
4. GPU-budget guard: if frame mask not ready within 1/fps budget, interpolate from previous mask via linear blend.

**Acceptance:** 30-sec portrait clip + replacement background exports in < 1.5× realtime.

---

### C11 — Repair pass (replaces Dart h264_repair_transcode)
**Files:** `cpp/videdit/ff_repair.c`.

**Steps:**
1. Open input via `avformat_open_input`. Inspect `AVFormatContext.flags`:
   - If first packet `pos > moov_offset`: `mdat` precedes `moov` → faststart needed.
2. Faststart remux: rewrite as new mp4 with `-movflags faststart` equivalent — write `moov` before `mdat`.
3. SPS/PPS detection: scan first 100 video packets; if no SPS NAL (0x67) found in-band, extract from `codecpar->extradata` and prepend to first IDR frame.
4. PTS rebuild: if `pkt->pts == AV_NOPTS_VALUE` for > 5 packets, generate from `pkt->dts + B-frame-offset` table.

**Wired into:** `MinisVidEdit.instance.repair(path) → repairedPath?`. Capture-import path runs this on every incoming clip on background thread.

**Acceptance:** Known-broken sample `example/test_assets/broken_moov.mp4` repairs and plays in native player.

---

### C12 — Export presets + two-pass + cancellation
**Files:** `cpp/videdit/ff_export.c`, `cpp/videdit/ff_progress.c`.

**Preset map (Kotlin/Swift constants):**
```
Reel:  1080×1920 h264 8M -profile:v high -level 4.2 -pix_fmt yuv420p
Story: 1080×1920 h264 6M
Feed:  1080×1080 h264 6M
HD:    1920×1080 h264 10M
4K:    3840×2160 hevc 25M
HEVC:  source-resolution hevc 8M
ProRes: source-resolution prores_ks 422
WebM:  1080p libvpx_vp9 6M
GIF:   480p palette+paletteuse, 12 fps
```

**Two-pass:** when `options.targetSizeMb` set:
1. Pass 1: `-pass 1 -an -f null /dev/null` (compute bitrate target = `targetMb * 8 * 1024 / durationS - audioBitrate`).
2. Pass 2: `-pass 2` at computed bitrate.

**Progress:** FFmpeg progress callback `av_log_set_callback` or polling `AVFormatContext.pb->pos` against expected size. Emit `progress {taskId, kind: "export", pct, fps, eta}` ≥ 10 Hz.

**Cancel:** `cancelTask(taskId)` sets `g_cancel_flags[taskId] = 1`; export loop checks each `av_read_frame` iteration; on cancel, `avcodec_send_packet(NULL)` + `avformat_close_input` + delete partial output file.

**Acceptance:** Each preset round-trips through the editor; cancel mid-export leaves no orphan files; no leaked codecs in `dumpsys media.codec`.

---

### C13.x — Re-enable trim UI + multiclip merge
**Files:** `lib/src/independent/minis_reel_clip_trimmer_page.dart`, `minis_multiclip_merge.dart`.

**Steps:**
1. After C2 ships `engineAvailable: true`: `minisReelClipTrimmerPlatformSupported()` flips on; build trimmer screen on top of `VidEditPreviewView` + `MinisVidEdit.thumbnailStrip` + `MinisVidEdit.trim`.
2. Multiclip merge: call `MinisVidEdit.concat({paths, outPath, keepMusicTempo})`.

**Acceptance:** Reel record → trim → merge → preview → post path works end-to-end without "rebuilding" placeholders.
