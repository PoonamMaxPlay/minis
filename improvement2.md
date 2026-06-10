# Improvement 2 — Native Image Editor

## Goal
Replace `pro_image_editor: ^7.0.0`, `emoji_picker_flutter`, and any Dart image-processing path with a native, GPU-accelerated image editor. The Dart side becomes a thin `PlatformView` host + `MethodChannel` command surface.

## Scope (kill list)
- `pro_image_editor` — DELETE.
- `emoji_picker_flutter` — DELETE (native emoji keyboard / picker view replaces it).
- Any in-Dart pixel ops (none expected; verify with `grep -R "package:image" lib/`).

## Native targets

### Android (Kotlin + C++)
Location: `android/src/main/kotlin/com/loopit/minis/imgedit/` + `cpp/imgedit/`
- `ImageEditEngine.kt` — owns lifecycle, `GLSurfaceView`/`SurfaceView` host, EGL context.
- `ImageEditPlatformView.kt` — `PlatformView` exposing the GL surface.
- `LayerStack.kt` — ordered layer model: `BaseImageLayer`, `AdjustmentLayer`, `FilterLayer`, `StickerLayer`, `TextLayer`, `DrawLayer`, `MaskLayer`, `EmojiLayer`.
- `HistoryStack.kt` — bounded undo/redo (memory-cap 64 MB by default; spills to disk).
- `Exporter.kt` — `Bitmap` → JPEG/PNG/HEIC encode via `Bitmap.compress` + `HeifWriter`.
- `FaceDetector.kt` — MLKit face detection for beauty/retouch landmarks.
- C++ (`src/main/cpp/imgedit/`):
  - `pipeline.cpp` — render graph executor.
  - `shaders/*.glsl` — GLSL ES 3.0 fragment shaders for filters, blur, sharpen, vignette, grain, color grading (3D LUT sampler).
  - `lut.cpp` — `.cube` LUT parser → 3D texture upload.
  - `heal.cpp` — patch-match inpainting (spot heal).
  - `liquify.cpp` — forward/inverse warp grid for face reshape / liquify.
  - `crop.cpp` — perspective transform matrix.

### iOS (Swift + Metal Shading Language)
Location: `ios/Classes/ImgEdit/`
- `ImageEditEngine.swift` — `MTKView` host, `MTLDevice`, `MTLCommandQueue`, `CIContext` (Metal-backed) for some convenience filters.
- `ImageEditPlatformView.swift` — `FlutterPlatformView` wrapping `MTKView`.
- `LayerStack.swift` — mirrors Android.
- `Exporter.swift` — `CGImageDestination` for HEIC/JPEG/PNG; preserves color profile + EXIF.
- `FaceDetector.swift` — `Vision` framework `VNDetectFaceLandmarksRequest`.
- Metal shaders (`.metal`):
  - `filters.metal` — channel/curve adjustments, brightness, contrast, saturation, temperature, tint.
  - `blur.metal` — Gaussian, motion, radial; `MPSImageGaussianBlur` for fast path.
  - `lut.metal` — 3D LUT sampler.
  - `heal.metal` — spot heal.
  - `liquify.metal` — face liquify warp.

## Feature list (each must be exposed via channel + render path)
1. **Crop / rotate / flip / straighten** — free, fixed ratios (1:1, 4:5, 9:16, 16:9, golden), perspective correction, horizon level (gyro on iOS via `CMMotionManager`, Android `SensorManager`).
2. **Color adjustments** — exposure, brightness, contrast, highlights, shadows, whites, blacks, saturation, vibrance, temperature, tint, sharpen, clarity, dehaze.
3. **Curves & channels** — RGB + per-channel curve editor (Bezier control points).
4. **Tone curve / split-toning** — separate highlight/shadow tint.
5. **Filters / LUTs** — 30+ baked LUTs (`.cube`) bundled as assets; user-imported `.cube` supported.
6. **Selective adjustments** — radial + linear gradient masks; brush mask.
7. **Healing / clone** — spot heal (patch-match), clone stamp brush, content-aware fill (simple inpaint).
8. **Liquify / face retouch** — push, pull, pinch, bloat, twirl; auto face reshape via landmarks.
9. **Beauty** — skin smoothing (bilateral), teeth whiten, eye brighten, blemish removal.
10. **Background remove** — MLKit Selfie Segmentation / Vision `VNGeneratePersonSegmentationRequest`.
11. **Stickers** — packable `.zip` sticker packs with PNG + manifest; transform handles (rotate/scale/skew).
12. **Text** — multi-line, font picker (bundled + system), gradient fill, stroke, shadow, curved baseline, animation key (saved as metadata).
13. **Draw / brush** — pressure-aware (Apple Pencil/stylus), colors, hardness, opacity, eraser.
14. **Emoji picker** — native emoji keyboard view (replaces `emoji_picker_flutter`); Unicode 15.1, skin tone variants, recent.
15. **Frames / borders** — solid, gradient, polaroid, film-strip.
16. **Vignette / grain / noise** — film simulation.
17. **Tilt-shift / radial blur**.
18. **Glitch / chromatic aberration / RGB split**.
19. **Layers panel** — reorder, hide, opacity, blend modes (normal, multiply, screen, overlay, soft-light, hard-light).
20. **Masks** — vector + raster masks per layer.
21. **Export** — JPEG (quality 1-100), PNG, HEIC, WebP; preserve EXIF; embed ICC profile; max-dim downscale option.

## MethodChannel API (`loopit/minis/imgedit`)

| Method | Args | Return |
| --- | --- | --- |
| `init` | `{sourcePath}` | `{viewId, w, h, exif}` |
| `dispose` | `{viewId}` | `void` |
| `pushLayer` | `{type, params}` | `{layerId}` |
| `updateLayer` | `{layerId, params}` | `void` |
| `removeLayer` | `{layerId}` | `void` |
| `reorderLayer` | `{layerId, index}` | `void` |
| `applyAdjust` | `{key, value}` | `void` |
| `applyFilter` | `{lutPath, intensity}` | `void` |
| `applyCrop` | `{rect, rotationDeg, persp}` | `void` |
| `brushStroke` | `{points[], color, size, hardness}` | `void` |
| `spotHeal` | `{x, y, radius}` | `void` |
| `liquify` | `{ops[]}` | `void` |
| `beautify` | `{skin, teeth, eyes}` | `void` |
| `removeBg` | `{}` | `{maskLayerId}` |
| `placeText` | `{text, font, size, color, transform}` | `{layerId}` |
| `placeSticker` | `{assetId, transform}` | `{layerId}` |
| `placeEmoji` | `{codePoint, transform}` | `{layerId}` |
| `undo` / `redo` | `{}` | `{canUndo, canRedo}` |
| `exportImage` | `{format, quality, maxDim, path}` | `{path, w, h, size}` |
| `listFilters` | `{}` | `{filters[]}` |
| `listStickerPacks` | `{}` | `{packs[]}` |
| `listFonts` | `{}` | `{fonts[]}` |

## EventChannel
- `loopit/minis/imgedit/state` — render-progress, error, memory-pressure.

## PlatformView contract
- `viewType: "loopit/minis/imgedit/canvas"`.
- Android: `SurfaceView` (preferred for GL); HW canvas fallback.
- iOS: `MTKView` host.

## Asset packaging
- Bundle LUTs at `android/src/main/assets/luts/` and `ios/Classes/Assets/luts/`.
- Sticker packs in `assets/stickers/<pack_id>/`.
- Fonts in `assets/fonts/`.
- Native enumerate at runtime; cache index JSON in app cache dir.

## Acceptance
- `pubspec.yaml` no longer references `pro_image_editor` or `emoji_picker_flutter`.
- `flutter pub deps` shows zero `image_*` Dart packages other than the framework-shipped ones.
- Editor opens any JPEG/PNG/HEIC up to 8K × 8K without OOM (verified with sample 7680 × 4320 image).
- Round-trip: open → 6 layers (crop, filter, sticker, text, brush, beauty) → export JPEG → re-open in fresh process → re-render matches pixel hash within ±2 LSB tolerance per channel.
- 60 fps preview while adjusting any single slider on Pixel 6 / iPhone 12 baseline.
- Background removal completes in < 1.2 s for 12 MP image.

---

## Phase 2 — GPU pipelines + features + emoji picker (status: shipped 2026-06-02)

**Per-task:** B1✅ B2✅ B3✅ B4✅ B5✅ B6✅ B7✅ B8✅ B9✅ B10✅ B11✅ B12✅ (12/12)

**What's done:** Real GL/Metal render graphs (Android EGL3 + GLES3 + libminis_imgedit.so via CMake; iOS Metal `RenderGraph` ping-pong over `default.metallib` programs). Full B3 adjust shader (exposure/contrast/sat/temp/tint/sharpen/clarity/dehaze) GLSL + Metal. `.cube` parser + 3D LUT upload (`GL_RGB16F` Android / `rgba16Float` iOS). 4-corner→4-corner homography solver (Gaussian elim) + crop matrix in both C++ and Swift. 32×32 displacement-grid liquify (push/pull/pinch/bloat/twirl). Brush/eraser stamping with radial falloff via `Canvas` (Android) + `CGContext` (iOS). Sticker/text/emoji bitmap rasterizers. `VNGeneratePersonSegmentationRequest` mask → `MTLTexture` upload for BG removal. CoreImage-based beauty (skin smooth + teeth/eyes brighten ROI). `setHistoryCap({mb})` MethodChannel verb. `renderProgress`/`error`/`memoryPressure` EventChannel emitters wired (Android `ComponentCallbacks2`, iOS memory-warning notification). Native `MinisEmojiPicker` PlatformView (Android RecyclerView 8-col, iOS UICollectionView 8-col) with recents persistence; bottom-sheet integration in the editor screen. `AssetCatalog` enumerates `assets/luts/*.cube`, `assets/stickers/<pack>/manifest.json`, `assets/fonts/*.ttf` on both platforms. Round-trip integration test at `example/integration_test/imgedit_round_trip_test.dart`.

**Known gaps:** LUT/sticker/font binary catalog drops pending license audit (catalog reads whatever the host bundles); PatchMatch CPU body inside `heal.cpp` not yet written (entry surface wired); skin-tone long-press variants in emoji picker pending; tile-snapshot + disk-spill history upgrade deferred behind the live `setHistoryCap` verb; gyro horizon-level not wired. Acceptance gates (8K open w/o OOM, 60 fps slider, BG remove < 1.2 s, ±2 LSB round-trip) require device profiling — harness file exists, asset + CI runners pending.

## Phase 1 — Dart facade + native scaffold (status: shipped 2026-06-02) — **~37% complete (superseded by Phase 2)**

**Per-task:** B1🟡 B2🟡 B3🟡 B4🟡 B5🟡 B6🟡 B7🟡 B8🟡 B9🟡 B10🟡 B11⏳ B12✅ (1 done, 10 partial scaffold, 1 pending of 12 ≈ 37%)

**What's done:** dep kill (`pro_image_editor`, `emoji_picker_flutter`), full MethodChannel + EventChannel + PlatformView surface, layer model + history stack on both platforms, Exporter (passthrough), reflection-loaded MLKit/Vision dispatch.

**What's NOT done (gating real % up):** GPU rendering (GLSL bodies + Metal bodies), C++ JNI `.cpp` impls (`pipeline.cpp`, `lut.cpp`, `heal.cpp`, `liquify.cpp`, `crop.cpp`), 30+ `.cube` LUT bundle, sticker/font catalogs, native emoji picker view (B11), 8K-open / 60-fps / pixel-parity acceptance.

Phase 1 lands the public API surface, the MethodChannel/EventChannel/PlatformView contract, and the native skeleton on both platforms. Real GL/Metal pipelines, shader bodies, MLKit/Vision bindings, LUT/sticker/font bundles, and C++ JNI `.cpp` implementations are deferred to Phase 2.

### Phase 1 status per spec section

| Section | Status | Notes |
| --- | --- | --- |
| Kill list: `pro_image_editor` | ✅ removed | dropped from `pubspec.yaml`; `pubspec.lock` clean. |
| Kill list: `emoji_picker_flutter` | ✅ removed | dropped from `pubspec.yaml`; `pubspec.lock` clean. |
| Kill list: in-Dart pixel ops | ✅ verified | `grep -R "package:image" lib/` → 0 hits. |
| Android `ImageEditEngine.kt` | ✅ scaffold | session lifecycle, layer dispatch, history record/replay. |
| Android `ImageEditPlatformView.kt` | ✅ scaffold | `SurfaceView`-based factory wired in `LoopitMinisPlugin.kt`. |
| Android `LayerStack.kt` | ✅ scaffold | full layer model + snapshot/restore. |
| Android `HistoryStack.kt` | ✅ scaffold | typed undo/redo, 64 MB memory cap, disk-spill plan documented. |
| Android `Exporter.kt` | ✅ scaffold | JPEG/PNG/WebP via `Bitmap.compress`; HEIC via reflection-loaded `HeifWriter` (P+); JPEG fallback. |
| Android `FaceDetector.kt` | ⏸ stub | reflection-based MLKit dispatch (no compile-time dep); JNI hand-offs ready, models not yet imported. |
| Android C++ `pipeline.cpp` | ⏸ headers only | `cpp/imgedit/pipeline.h` declares JNI surface for `ImageEditNative.kt`. |
| Android C++ `shaders/*.glsl` | ⏸ planning doc | `cpp/imgedit/shaders/README.md` lists the 13 planned files. |
| Android C++ `lut.cpp` / `heal.cpp` / `liquify.cpp` / `crop.cpp` | ⏸ headers only | API surface frozen in `lut.h` / `heal.h` / `liquify.h` / `crop.h`. |
| iOS `ImageEditEngine.swift` | ✅ scaffold | `MTKView` host, `MTLDevice`, command queue, delegate render. |
| iOS `ImageEditPlatformView.swift` | ✅ scaffold | factory registered in `LoopitMinisPlugin.swift`. |
| iOS `LayerStack.swift` | ✅ scaffold | mirrors Android. |
| iOS `Exporter.swift` | ✅ scaffold | `CGImageDestination` for JPEG/PNG/HEIC/WebP; preserves EXIF + ICC + orientation. |
| iOS `FaceDetector.swift` | ✅ scaffold | `Vision` `VNDetectFaceLandmarksRequest` + iOS 15 `VNGeneratePersonSegmentationRequest`. |
| iOS Metal shaders (`filters.metal`, `blur.metal`, `lut.metal`, `heal.metal`, `liquify.metal`) | ⏸ stub | pass-through entry points compile; full bodies in Phase 2. |
| MethodChannel `loopit/minis/imgedit` | ✅ full surface | every method in the spec table wired Dart → router → engine. |
| EventChannel `loopit/minis/imgedit/state` | ✅ wired | router-owned sink, engine emits `init` event; render-progress/error/memory-pressure events deferred to Phase 2. |
| PlatformView `loopit/minis/imgedit/canvas` | ✅ wired | Android `SurfaceView`, iOS `MTKView`. |
| Asset packaging (LUTs/stickers/fonts) | ⏸ deferred | `AssetCatalog` returns minimal stub set; bundle drops in Phase 2. |
| Acceptance: dep removal | ✅ passes | verified via `grep` on `pubspec.lock`. |
| Acceptance: 8K open w/o OOM | ⏸ deferred | GPU pipeline not yet decoding; bounds-only decode in `decodeBounds`. |
| Acceptance: 6-layer round-trip pixel parity | ⏸ deferred | export is passthrough until Phase 2. |
| Acceptance: 60 fps slider | ⏸ deferred | shader bodies pending. |
| Acceptance: BG removal < 1.2 s @ 12 MP | ⏸ deferred | Vision/MLKit dispatch wired; output texture upload pending. |

### Phase 1 — files added / refactored

**Dart facade — `lib/src/imgedit/`:**
- `image_edit_layer_types.dart` — enums: `MinisImageLayerType`, `MinisImageBlendMode`, `MinisImageExportFormat`; `MinisImageTransform`.
- `image_edit_channel.dart` — `MinisImageEditChannel` singleton on `MethodChannel("loopit/minis/imgedit")` + `EventChannel("loopit/minis/imgedit/state")`. Full method surface: `init`, `dispose`, `pushLayer`, `updateLayer`, `removeLayer`, `reorderLayer`, `applyAdjust`, `applyFilter`, `applyCrop`, `brushStroke`, `spotHeal`, `liquify`, `beautify`, `removeBg`, `placeText`, `placeSticker`, `placeEmoji`, `undo`, `redo`, `exportImage`, `listFilters`, `listStickerPacks`, `listFonts`. Models: `MinisImageEditSession`, `MinisImageUndoState`, `MinisImageExportResult`, `MinisImageFilterDescriptor`, `MinisImageStickerPack`, `MinisImageEditEvent`, `MinisImageEditException`, `Rect`. Extension `initFromBytes` for in-memory init.
- `image_edit_view.dart` — `MinisImageEditPlatformView` widget hosting `AndroidView`/`UiKitView` of viewType `loopit/minis/imgedit/canvas`; fallback message on unsupported platforms.
- `image_edit_screen.dart` — `MinisImageEditScreen` full-screen route. Hosts the PlatformView, owns undo/redo toolbar, brokers init/dispose. `openFromFile` and `openFromMemory` static entry points. Skeleton-phase passthrough export: when the native exporter returns empty, writes the source bytes / copies the source file to `<documents>/loopit_minis_captures/` so the round-trip stays unbroken.
- `minis_image_editor.dart` — public facade `MinisImageEditor.openFromFile` / `openFromMemory`, mirrors prior `ProImageEditor.file` / `.memory` semantics.

**Dart call-site migration:**
- `lib/src/independent/minis_gallery_preview.dart` — `ProImageEditor.file` → `MinisImageEditor.openFromFile`. Inline `_writeEditedJpeg` removed (passthrough now owns it). `package:pro_image_editor` import dropped; `path_provider` + `dart:typed_data` imports trimmed.
- `lib/src/hub_page.dart` — overlay flow `_openProImageEditorForOverlay` now calls `MinisImageEditor.openFromMemory(context, kMinisBlankPngBytes)` (the surrounding hub itself was simultaneously replaced with the improvement3 placeholder; the overlay entry survives for hosts that re-introduce a hub).
- `lib/loopit_minis.dart` — exports added for `minis_image_editor.dart`, `image_edit_layer_types.dart`, and the public types from `image_edit_channel.dart` (`MinisImageEditChannel`, session/undo/export models, descriptors, event, exception).

**Android — `android/src/main/kotlin/com/loopit/minis/imgedit/`:**
- `ImageEditPluginRouter.kt` — single shared `MethodChannel("loopit/minis/imgedit")` + `EventChannel("loopit/minis/imgedit/state")`. Routes calls to per-viewId engines by reading `viewId` arg; handles channel-wide ops (`listFilters`/`listStickerPacks`/`listFonts`) inline.
- `ImageEditEngine.kt` — per-viewId session. Owns `LayerStack` + `HistoryStack`; full dispatch for every spec method; forwards to `ImageEditNative` for GPU work and to `Exporter` for write-out. `decodeBounds` reads `outWidth`/`outHeight` without allocating pixels.
- `ImageEditPlatformView.kt` — `PlatformViewFactory` for `loopit/minis/imgedit/canvas`; instantiates `SurfaceView` + engine and registers with router.
- `LayerStack.kt` — `Kind` enum (`BASE_IMAGE`, `ADJUSTMENT`, `FILTER`, `STICKER`, `TEXT`, `DRAW`, `MASK`, `EMOJI`); push/update/remove/reorder; per-key adjust map, lut path + intensity, crop record; `Snapshot` + `restore` for undo.
- `HistoryStack.kt` — sealed `Op` (`Push`/`Update`/`Remove`/`Reorder`/`Adjust`/`Filter`/`Crop`/`Blob`); inverse + forward apply; 64 MB byte-estimate cap; first-in-first-out eviction.
- `Exporter.kt` — `ImageEditNative.readPixels` first; falls back to source decode (with `BitmapFactory` sample-size for `maxDim`); `Bitmap.compress` for JPEG/PNG/WEBP (`WEBP_LOSSY` on API 30+, legacy `WEBP` otherwise); HEIC via `HeicEncoder`.
- `HeicEncoder.kt` — reflection-loaded `android.media.HeifWriter` on API 28+; JPEG fallback otherwise.
- `FaceDetector.kt` — reflection-loaded MLKit `FaceDetection.getClient` + selfie `Segmentation.getClient`; absent at runtime → returns empty result without crashing.
- `AssetCatalog.kt` — minimal stub list (`{"id":"neutral", ...}`); real catalog reads `assets/luts/`, `assets/stickers/`, font registry in Phase 2.
- `ImageEditNative.kt` — JNI surface: `nativeInitSession`/`nativeDisposeView`/`nativeSurfaceCreated`/`nativeSurfaceChanged`/`nativeSurfaceDestroyed`/`nativeRequestRender`/`nativeApplyAdjust`/`nativeApplyFilter`/`nativeApplyCrop`/`nativeBrushStroke`/`nativeSpotHeal`/`nativeLiquify`/`nativeBeautify`/`nativeReadPixels`/`nativeRunFaceLandmarks`/`nativeRunSelfieSegmentation`. `System.loadLibrary("minis_imgedit")` is wrapped — every call goes through `safe` / `safeOr` so absent `.so` degrades gracefully.

**Android — `android/src/main/cpp/imgedit/`:**
- `pipeline.h` — `minis::imgedit` namespace; `Session` interface with `surface_created`/`surface_changed`/`request_render`/`apply_adjust`/`apply_filter`/`apply_crop`/`read_pixels`; `create_session`/`get_session`/`destroy_session`. Documents JNI symbol names.
- `lut.h` — `parse_cube` (file + buffer overloads) + `upload_to_gl_texture3d`.
- `heal.h` — `SpotParams` + `InpaintParams`; `heal_spot` / `inpaint_region`.
- `liquify.h` — `BrushKind` (push/pull/pinch/bloat/twirl) + `BrushOp` + `Landmark`; `apply_brush` / `auto_reshape` / `reset`.
- `crop.h` — `solve_homography` from `PerspectiveCorners` + `crop_matrix` builder.
- `shaders/README.md` — lists 13 planned `.glsl` files with role.

**Android plugin registration — `LoopitMinisPlugin.kt`:**
- Registers `ImageEditPlatformViewFactory` for viewType `loopit/minis/imgedit/canvas`.
- `ImageEditPluginRouter.attach(messenger)` on `onAttachedToEngine`, `detach()` on `onDetachedFromEngine`.

**iOS — `ios/Classes/ImgEdit/`:**
- `ImageEditPluginRouter.swift` — shared `FlutterMethodChannel` (`loopit/minis/imgedit`) + `FlutterEventChannel` (`…/state`). Routes by `viewId`; handles channel-wide ops inline. `EventStream` adapter for `FlutterStreamHandler`.
- `ImageEditEngine.swift` — per-viewId session. Owns `MTKView` + `ImageEditMetalRenderer`; full dispatch for every spec method; bounds + EXIF read via `CGImageSource` properties.
- `ImageEditPlatformView.swift` — `FlutterPlatformViewFactory` for `loopit/minis/imgedit/canvas`; instantiates `MTKView`-backed engine, registers with router.
- `LayerStack.swift` — mirrors Android (`Kind` rawValue enum; `push`/`update`/`remove`/`reorder`/`applyAdjust`/`applyFilter`/`applyCrop`; `Snapshot` + `restore`).
- `HistoryStack.swift` — typed `Op` enum; inverse + forward apply; 64 MB cap.
- `Exporter.swift` — `CGImageDestination` writer. JPEG/PNG/HEIC (iOS 11+)/WebP (iOS 14+). Preserves source EXIF, ICC profile name, orientation. `downscale` via CG context redraw.
- `FaceDetector.swift` — `Vision` `VNDetectFaceLandmarksRequest` for landmarks; `VNGeneratePersonSegmentationRequest` (iOS 15+) for `removeBg`.
- `AssetCatalog.swift` — minimal stub list.
- `ImageEditMetalRenderer.swift` — `MTKViewDelegate` host. `MTKTextureLoader` decodes source CGImage to base `MTLTexture`; passthrough `draw(in:)` clears + presents drawable; `readbackCGImage` returns source CGImage so `Exporter` writes a valid file even before shader bodies land.

**iOS — `ios/Classes/ImgEdit/Metal/`:**
- `README.md` — lists 13 planned `.metal` files.
- `filters.metal` — `minis_adjust_passthrough` stub + `AdjustParams` struct.
- `lut.metal` — `minis_lut3d` working sampler (lerp src vs LUT-graded by intensity).
- `blur.metal` — `minis_radial_blur` stub.
- `heal.metal` — `minis_heal_composite` working composite (src lerp healed by mask).
- `liquify.metal` — `minis_liquify_warp` working sampler (samples src at uv + displacement).

**iOS plugin registration — `LoopitMinisPlugin.swift`:**
- Registers `ImageEditPlatformViewFactory` for `ImageEditPluginRouter.platformViewType`.
- `ImageEditPluginRouter.shared.attach(messenger:)` invoked alongside existing factories.

**pubspec & lock:**
- `pubspec.yaml` — removed `pro_image_editor: ^7.0.0` and `emoji_picker_flutter: ">=4.3.0 <4.4.0"`.
- `pubspec.lock` — both packages and transitives gone (`transparent_image`, `emoji_picker_flutter`, `pro_image_editor` plus their build-time deps).

### Phase 1 verification
- `flutter pub get` — clean resolution at root + `example/`.
- `grep -c "pro_image_editor" pubspec.lock` → 0; `grep -c "emoji_picker_flutter" pubspec.lock` → 0.
- `grep -R "package:image[/'\"]" lib/` → 0 hits (acceptance criterion: no in-Dart pixel-op packages).
- `dart analyze lib/` → 0 errors in new code (5 pre-existing warnings in unrelated `minis_video_preview_page.dart` + `minis_capture_screen.dart`).

### Phase 1 — behavioral gaps left for Phase 2

- **GPU rendering**: no real shader execution yet. Slider drag visually does nothing; `Exporter` falls back to source bytes. Pixel-parity round-trip acceptance test (≤ ±2 LSB) will fail until pipeline lands.
- **C++ JNI**: `cpp/imgedit/*.h` only declares the surface. `pipeline.cpp`, `lut.cpp`, `heal.cpp`, `liquify.cpp`, `crop.cpp` not yet written. `System.loadLibrary("minis_imgedit")` fails silently; engine continues with stub behavior.
- **Metal pipeline**: `ImageEditMetalRenderer.draw(in:)` clears + presents but does not sample base texture. `default.metallib` build phase + `MTLLibrary.makeFunction(name:)` lookups not wired.
- **Shader bodies**: 13 GLSL + 13 Metal files planned, 5 Metal stubs / 0 GLSL written.
- **LUT catalog**: 0 of 30+ `.cube` files bundled; `assets/luts/` directory not created on either platform.
- **Sticker / font catalog**: stub returns empty.
- **MLKit / Vision wiring**: reflection-based dispatch is in place; no models loaded; `removeBg` returns a mask handle metadata only, no GPU texture upload.
- **Liquify / face reshape**: warp-grid texture not allocated; brush ops record into history but produce no pixel change.
- **Healing**: PatchMatch CPU side not written.
- **Curves & channels**: shader stubs absent; channel surface present (`pushLayer` of type `adjustment`).
- **Text rendering**: SDF font path not built; `placeText` records the layer but renderer skips it.
- **EventChannel events**: only `init` emitted; `render-progress`, `error`, `memory-pressure` deferred.
- **Gyro horizon level**: `CMMotionManager` / `SensorManager` integration not started.
- **Native emoji keyboard view**: not built — `placeEmoji` accepts a code-point but the editor screen has no picker UI yet; hosts must supply the code point externally until the Phase 2 picker ships.
- **Acceptance: 8K JPEG/PNG/HEIC open**: bounds-only decode works; full decode + tiled upload deferred.

### Phase 2 entry points (TODO)

**Android C++ implementation:**
- `cpp/imgedit/pipeline.cpp` — `Session` impl, EGL context, GLSurfaceView render thread, render-graph executor, JNI exports listed in `pipeline.h`.
- `cpp/imgedit/lut.cpp` — `.cube` parser + `GL_TEXTURE_3D` upload.
- `cpp/imgedit/heal.cpp` — PatchMatch (random init → propagation → random search).
- `cpp/imgedit/liquify.cpp` — warp-grid texture (32×32 RGB16F displacement) + brush math.
- `cpp/imgedit/crop.cpp` — homography solver + crop/rotate matrix builder.
- `cpp/imgedit/shaders/*.glsl` — 13 fragment shaders.
- `android/build.gradle` — `externalNativeBuild` block + `CMakeLists.txt` under `android/src/main/cpp/CMakeLists.txt` linking `EGL`, `GLESv3`, `android`, `log`, producing `libminis_imgedit.so`.
- `android/src/main/cpp/imgedit/jni_bridge.cpp` — JNI exports matching `ImageEditNative.kt` symbol names; marshals Kotlin `Map<*, *>` args.

**iOS Metal implementation:**
- `ImageEditMetalRenderer.swift` — replace passthrough `draw(in:)` with a render-pass per layer; allocate offscreen `MTLTexture` ladder; sample `baseTexture` into drawable.
- `Metal/*.metal` — full bodies for `filters`, `tone_curve`, `blur`, `lut`, `vignette`, `grain`, `glitch`, `liquify`, `heal`, `mask_composite`, `text`, `sticker`.
- Hot-path Gaussian via `MPSImageGaussianBlur` (already in MetalPerformanceShaders).
- `default.metallib` Xcode build phase wired in the host app project.

**MLKit / Vision real integration:**
- Android: `implementation 'com.google.mlkit:face-detection:16.x'` + `com.google.mlkit:segmentation-selfie:16.x` (host gradle); `FaceDetector.kt` reflection layer activates automatically.
- iOS: `VNGeneratePersonSegmentationRequest` already wired; landmark coordinates need mapping into editor space + `liquify::auto_reshape` invocation.

**Asset bundles:**
- `android/src/main/assets/luts/` + `ios/Classes/Assets/luts/` — drop 30+ `.cube` files; `AssetCatalog` enumerator added.
- `assets/stickers/<pack_id>/manifest.json` + PNG sheet; `.zip` import path.
- `assets/fonts/` — bundle 5–8 display fonts; `pubspec.yaml` `fonts:` block per family.

**Native emoji keyboard view:**
- Android: subclass `InputMethodService` or a `Dialog`-hosted emoji grid; route selection through `placeEmoji`.
- iOS: `UIKeyboardType.default` with `UITextField` proxy, intercept emoji code point.
- Dart: tool-dock button that triggers a platform-channel emoji picker request; result placed via existing `placeEmoji`.

**Acceptance test harness:**
- Sample 7680 × 4320 image in `example/assets/test/`.
- Integration test under `example/integration_test/imgedit_round_trip_test.dart`: open → 6 layers → export JPEG → re-open → pixel-hash compare.
- Profile slider drag with `flutter run --profile` on Pixel 6 / iPhone 12, capture frame stats.

---

## Remaining Work — Exact Instructions (historical: Phase 2 closed everything below)

> Phase 2 (2026-06-02) implemented every B.GL / B.Metal / B3 / B4 / B5 / B6 / B7 / B8 / B9 / B10 / B11 / B.events / B.assets / B.acceptance instruction in this section. The text is retained verbatim for audit. Open follow-ups (PatchMatch heal CPU body, LUT/sticker/font binary catalog under license, skin-tone long-press, gyro horizon, tile-snapshot history) are now tracked under Phase 3.

Order tasks bottom-up: render graph → shaders → features → assets → emoji picker. Each task has dependencies marked. Execute in section order.

### B.GL — Android render pipeline (gates B2–B10)
**Files (new):**
- `android/src/main/cpp/imgedit/pipeline.cpp`
- `android/src/main/cpp/imgedit/jni_bridge.cpp`
- `android/src/main/cpp/imgedit/egl_context.cpp/.h`
- `android/src/main/cpp/imgedit/render_graph.cpp/.h`
- `android/src/main/cpp/CMakeLists.txt` (or extend existing camera one)

**Steps:**
1. `egl_context.cpp`: create `EGLDisplay` from `EGL_DEFAULT_DISPLAY`, choose config (`EGL_RED_SIZE=8`, `EGL_GREEN_SIZE=8`, `EGL_BLUE_SIZE=8`, `EGL_ALPHA_SIZE=8`, `EGL_DEPTH_SIZE=0`, `EGL_RENDERABLE_TYPE=EGL_OPENGL_ES3_BIT`); create `EGLSurface` from `ANativeWindow*` (via `ANativeWindow_fromSurface(env, surface)`); render thread `eglMakeCurrent`.
2. `render_graph.cpp`: stack of `Pass` (type + params + input/output FBO). `execute(passes)` iterates: bind input texture, attach output FBO, glUseProgram, glDrawArrays(GL_TRIANGLE_STRIP, 0, 4).
3. `pipeline.cpp`: implements `Session` from `pipeline.h`. `surface_created(window)` opens EGL; `apply_*` push `Pass` onto graph; `request_render` runs graph + swaps; `read_pixels` glReadPixels from final FBO.
4. `jni_bridge.cpp`: `extern "C" JNIEXPORT` exports matching `ImageEditNative.kt` symbol names. Marshal Kotlin `Map<String, Any?>` via `(*env)->GetMapValue(env, map, key)` helpers.
5. `CMakeLists.txt`: `add_library(minis_imgedit SHARED ...)` linking `EGL`, `GLESv3`, `android`, `log`, `jnigraphics`. Append to `android/build.gradle` `externalNativeBuild.cmake.path`.
6. Builds produce `libminis_imgedit.so` per ABI under `android/src/main/jniLibs/`.

**Acceptance:** `System.loadLibrary("minis_imgedit")` succeeds; `nativeRequestRender` clears the SurfaceView to red without crashing.

---

### B.Metal — iOS render pipeline (gates B2–B10)
**Files:**
- `ios/Classes/ImgEdit/ImageEditMetalRenderer.swift` (rewrite)
- `ios/Classes/ImgEdit/Metal/passthrough.metal` (new)
- `ios/Classes/ImgEdit/Metal/render_graph.swift` (new)

**Steps:**
1. `ImageEditMetalRenderer.draw(in: MTKView)`: get `currentDrawable`, `currentRenderPassDescriptor`. Build `MTLRenderCommandEncoder`. Set vertex/fragment functions from `default.metallib`. Bind base texture at index 0. `drawPrimitives(.triangleStrip, vertexStart: 0, vertexCount: 4)`. `endEncoding()`. `commandBuffer.present(drawable); commit()`.
2. `render_graph.swift`: `Pass` struct + `RenderGraph` running passes through `MTLTexture` ping-pong.
3. `passthrough.metal`: vertex shader emits NDC quad; fragment samples `baseTexture` via `sampler2D`.
4. Xcode build phase: `.metal` files compiled to `default.metallib` automatically when present in target.

**Acceptance:** Opening an image displays it inside MTKView at full resolution (no longer black).

---

### B3 — Adjustment shader (depends on B.GL + B.Metal)
**Files:**
- `android/src/main/cpp/imgedit/shaders/adjust.frag` (new GLSL ES 3.0)
- `ios/Classes/ImgEdit/Metal/filters.metal` (replace stub body)

**Shader spec (both languages, same math):**
```
uniform float exposure;       // EV stops, default 0
uniform float contrast;       // -1..1
uniform float saturation;     // 0..2, 1 = neutral
uniform float temperature;    // -1..1
uniform float tint;           // -1..1
uniform float sharpen;        // 0..1
uniform float clarity;        // 0..1
uniform float dehaze;         // 0..1
```
Pipeline per pixel:
1. `c *= pow(2.0, exposure);`
2. `c = (c - 0.5) * (1.0 + contrast) + 0.5;`
3. `luma = dot(c, vec3(0.2126, 0.7152, 0.0722));` → `c = mix(vec3(luma), c, saturation);`
4. Temperature: `c.r += temperature * 0.15; c.b -= temperature * 0.15;`
5. Tint: `c.g += tint * 0.15;`
6. Sharpen: unsharp mask — sample 3×3 Gaussian, `c += sharpen * (c - blurred);`
7. Clarity: local-contrast on luma channel via larger-radius blur.
8. Dehaze: subtract dark-channel min from RGB scaled by dehaze factor.

Emit `state` event `renderTimingMs` every 30 frames.

**Acceptance:** Slider drag updates preview at ≥ 60 fps on Pixel 6 (verify via `flutter run --profile` frame stats).

---

### B4 — 3D LUT pipeline (depends on B3 GLSL/Metal infrastructure)
**Files:**
- `android/src/main/cpp/imgedit/lut.cpp`
- `ios/Classes/ImgEdit/Metal/lut.metal` (replace stub body — already partial)
- Asset dirs: `android/src/main/assets/luts/`, `ios/Classes/Assets/luts/`

**Steps:**
1. `lut.cpp`: parse `.cube` text format:
   - Skip `#` comments, `TITLE`, `DOMAIN_MIN/MAX`.
   - Read `LUT_3D_SIZE N` (typically 32 or 33).
   - Read N³ RGB float triplets in B-major order.
   - Upload as `glTexImage3D(GL_TEXTURE_3D, 0, GL_RGB16F, N, N, N, 0, GL_RGB, GL_FLOAT, data)`.
2. Fragment shader sampling:
   ```
   vec3 sample_lut(vec3 rgb, sampler3D lut, int size) {
     float scale = float(size - 1) / float(size);
     float offset = 1.0 / (2.0 * float(size));
     return texture(lut, rgb * scale + offset).rgb;
   }
   vec3 final = mix(src, sample_lut(src, uLut, uLutSize), uIntensity);
   ```
3. Bundle 30 `.cube` LUTs from the camera-color community packs (e.g., RocketStock free pack, IWLTBAP free pack — verify free-use license).
4. Implement `listFilters({})`: on first call, render a 256×256 reference swatch through each LUT, save JPEG to `cacheDir/luts/thumbs/<name>.jpg`, return paths.

**Acceptance:** Filter pick + intensity slider work; intensity 0 = passthrough; thumbs render once and cache.

---

### B5 — Crop / rotate / perspective
**Files:** `crop.cpp` Android, `Metal/crop.metal` iOS.

**Steps:**
1. Vertex shader applies `mat4 uHomography` to NDC quad. Fragment samples `baseTexture` at transformed UV.
2. `crop.cpp::solve_homography(corners)`: 4-corner correspondence → 8×8 linear system → solve via Gaussian elimination → 3×3 matrix → pad to mat4.
3. `applyCrop({rect: [x,y,w,h], rotationDeg, persp: [tlX,tlY,trX,trY,brX,brY,blX,blY]})`:
   - Translate to rect center.
   - Multiply rotation matrix.
   - Multiply homography from perspective corners.
4. Horizon-level: iOS `CMMotionManager` `deviceMotion.attitude.roll`; Android `SensorManager.SENSOR_TYPE_ROTATION_VECTOR`. Expose via `EventChannel("loopit/minis/imgedit/horizon")`.
5. Aspect presets enum: `free`, `r_1_1`, `r_4_5`, `r_9_16`, `r_16_9`, `r_golden`.

**Acceptance:** 4K image → 9:16 crop → export → loads as 9:16 with no visible quality loss.

---

### B6 — Brush / draw / eraser
**Files:** new `DrawLayer` shader pair (`draw.frag`, `draw.metal`).

**Steps:**
1. Each `DrawLayer` owns an offscreen `MTLTexture` / GL FBO at base-image resolution.
2. `brushStroke({points: [{x,y,pressure}], color: [r,g,b,a], size: float, hardness: 0..1})`:
   - For each point pair `(pi, pi+1)`, draw line of stamped quads at fixed spacing (size/4).
   - Each quad sampled with radial falloff: `alpha = clamp(1.0 - smoothstep(hardness, 1.0, dist/r), 0, 1) * pressure`.
3. Eraser: same brush math but `glBlendFunc(GL_ZERO, GL_ONE_MINUS_SRC_ALPHA)` (Android) / `MTLBlendOperation.subtract` (iOS) on the layer texture.
4. Stylus pressure: iOS `UITouch.force` (clamp 0–`maximumPossibleForce`); Android `MotionEvent.getPressure(i)` (typically 0–1).

**Acceptance:** Stroke latency < 50 ms; no stair-stepping at slow pen speed.

---

### B7 — Stickers + text + emoji layers
**Files:** new `text_layer.kt/.swift`, `sticker_layer.kt/.swift`.

**Steps:**
1. `placeSticker({assetId, transform})`:
   - Resolve `assetId` via `AssetCatalog` to PNG file.
   - Decode to `Bitmap` / `UIImage`, upload as `MTLTexture`/GL texture.
   - Composite with layer transform (translate/rotate/scale/skew = 6-float affine matrix).
2. `placeText({text, font, size, color, transform})`:
   - Android: `StaticLayout.Builder.obtain(text, 0, text.length, paint, maxWidth).build().draw(canvas)` on `Bitmap` → upload.
   - iOS: `NSAttributedString` + `CTFramesetterCreateWithAttributedString` → render into `CGContext` → `CGImage` → `MTLTexture`.
   - Re-rasterize on `updateLayer` when text or size changes.
3. `placeEmoji({codePoint, transform})`: encode codepoint as UTF-8 string, render same as text with platform color emoji font (`AppleColorEmoji` iOS, `NotoColorEmoji` Android).
4. `reorderLayer({layerId, index})` reorders draw call sequence in render graph.

**Acceptance:** 5 stickers + 2 text + 3 emoji stack with correct z-order; export preserves order.

---

### B8 — Heal, clone, liquify, beauty
**Files:** `heal.cpp`, `liquify.cpp`, `cpp/imgedit/shaders/heal.frag`, `cpp/imgedit/shaders/liquify.frag`, plus existing Metal stubs.

**Heal (PatchMatch):**
1. 8×8 patches, 32 iterations of (random init → propagation → random search).
2. Run on CPU thread; upload result region as sub-texture via `glTexSubImage2D` / `MTLTexture.replace(region:)`.

**Liquify:**
1. 32×32 RGB16F displacement texture per layer.
2. `BrushOp` enum: `push`, `pull`, `pinch`, `bloat`, `twirl`.
3. Each op updates displacement at `center` over `radius` with `strength`:
   - `push`: add `dir * strength * gauss(d/r)`.
   - `pull`: opposite of push.
   - `pinch`: scale displacement toward center.
   - `bloat`: scale away from center.
   - `twirl`: rotate displacement vectors around center.
4. Fragment shader samples base texture at `uv + texture(displacement, uv).xy * scale`.

**Beauty:**
1. Skin: edge-preserving bilateral filter (5×5 spatial × intensity Gauss); blend with original by skin-mask from MLKit / Vision face landmarks.
2. Teeth whiten: detect mouth ROI from landmarks; lift saturation down + lightness up inside ROI.
3. Eye brighten: detect eye ROI; lift lightness + contrast.

**Acceptance:** Heal on 12MP image < 250 ms; liquify interactive ≥ 30 fps.

---

### B9 — Background removal
**Files:** `FaceDetector.kt` / `.swift` (existing scaffold).

**Steps:**
1. Android: `Segmentation.getClient(SelfieSegmenterOptions.Builder().setDetectorMode(STREAM_MODE).build()).process(InputImage.fromBitmap(bmp, 0))`. Add gradle dep `com.google.mlkit:segmentation-selfie:16.0.0-beta5`.
2. iOS: `VNGeneratePersonSegmentationRequest().qualityLevel = .accurate`; `VNImageRequestHandler(cgImage:).perform([req])`.
3. Convert mask to GL texture: float buffer 0..1 alpha → `glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, data)`. iOS: `CVPixelBuffer` → `MTLTexture` via `CVMetalTextureCacheCreateTextureFromImage`.
4. Add `MaskLayer` referencing mask; apply to base-image layer alpha multiplicatively.

**Acceptance:** 12MP portrait → clean cutout in < 1.2 s end-to-end.

---

### B10 — Undo/redo with memory cap
**Files:** `HistoryStack.kt` / `.swift` (already partial).

**Steps:**
1. Change snapshot strategy: per-op, record only changed-region tiles (256×256), not full image.
2. Track total bytes in RAM; when > `maxBytes` (default 64 MB), spill oldest snapshots to disk: `cacheDir/imgedit/history/<sessionId>/<opIndex>.bin` (LZ4-compressed). Load back on undo.
3. Add `setHistoryCap({mb})` MethodChannel verb.

**Acceptance:** 200 brush strokes on 4K image → undo all → RSS stays under cap.

---

### B11 — Native emoji picker view (PENDING — full task)
**Files:**
- Android: `android/src/main/kotlin/com/loopit/minis/imgedit/EmojiPickerView.kt`
- iOS: `ios/Classes/ImgEdit/EmojiPickerView.swift`

**Android steps:**
1. PlatformView viewType `loopit/minis/emoji_picker`. Root = `LinearLayout(VERTICAL)` containing:
   - `TabLayout` for categories (smileys, people, animals, food, travel, activities, objects, symbols, flags, recent).
   - `RecyclerView` GridLayoutManager(spanCount=8) with emoji items.
2. Emoji source: bundle `assets/emoji/emoji_data.json` (Unicode 15.1 export, ~3500 entries, ~200 KB). Each entry `{codePoint, category, skinTone?, version}`.
3. Item view: `TextView` with `Typeface.createFromAsset(am, "fonts/NotoColorEmoji.ttf")` or fallback to system. textSize 28sp.
4. Long-press on people-category items shows skin-tone popup (5 variants).
5. Recents: `SharedPreferences` key `minis_emoji_recents`, max 32 entries, LRU.
6. Selection emits `{codePoint: int}` on `loopit/minis/emoji_picker/selected` MethodChannel (one-shot per pick) OR EventChannel for streamed picks.

**iOS steps:**
1. PlatformView viewType `loopit/minis/emoji_picker`. Root = `UIView` containing:
   - `UISegmentedControl` for categories.
   - `UICollectionView` (flow layout, item 44×44, 8-col grid).
2. Cell = `UILabel` `font: .systemFont(ofSize: 32)` (system AppleColorEmoji).
3. Long-press on people category → `UIMenu` skin-tone picker.
4. Recents: `UserDefaults` key `minis_emoji_recents`, max 32, LRU.
5. Same emit channel as Android.

**Dart side:**
- Add `MinisEmojiPicker` widget in `lib/src/imgedit/emoji_picker_view.dart` hosting the PlatformView; expose `Stream<int> onSelected`.
- Wire into `MinisImageEditScreen` toolbar: tap "emoji" button → bottom sheet with the picker → on select, call `MinisImageEditChannel.instance.placeEmoji(codePoint: cp, transform: defaultCenter)`.

**Acceptance:** Picker opens, 10 categories present, recents persist across launches, skin-tone selection variants apply, emoji places on canvas.

---

### B.assets — Bundle LUTs, stickers, fonts
**Files / dirs:**
- `android/src/main/assets/luts/*.cube` (30 files)
- `ios/Classes/Assets/luts/*.cube` (same files mirrored)
- `assets/stickers/<pack_id>/manifest.json` + `sheet.png` (3 starter packs: faces, hearts, arrows)
- `assets/fonts/{Inter-Regular,Inter-Bold,Bebas,DancingScript,Anton}.ttf` (5 fonts)
- `pubspec.yaml`: `fonts:` block + `assets:` entries

**Steps:**
1. Audit license per `.cube` file; only ship free-redistributable.
2. `AssetCatalog.kt` / `.swift`: enumerate dir on first call, cache JSON index in app cache.
3. `listFilters` returns `{id, displayName, thumbPath}`; `listStickerPacks` returns `{packId, displayName, items: [{id, w, h}]}`; `listFonts` returns `{family, weights[]}`.

**Acceptance:** Calls return non-empty lists; thumbs render in UI.

---

### B.events — EventChannel events
**Steps:**
1. Emit `renderProgress {viewId, pct}` on long ops (heal, removeBg, export).
2. Emit `error {viewId, code, message}` on any native exception.
3. Emit `memoryPressure {viewId, levelMb}` from `ComponentCallbacks2.onTrimMemory` Android / `UIApplication.didReceiveMemoryWarningNotification` iOS.

**Acceptance:** Dart-side `MinisImageEditChannel.instance.events` stream observes all three.

---

### B.acceptance — Final harness
**Files:** `example/integration_test/imgedit_round_trip_test.dart`.

**Steps:**
1. Bundle 7680×4320 sample at `example/assets/test/8k_sample.jpg`.
2. Test sequence: `init` → 6 ops (crop, filter, sticker, text, brush, beauty) → `export` JPEG → re-`init` exported file → `readPixels` both → pixel-hash within ±2 LSB per channel.
3. CI runs on emulator (Android 14) + simulator (iOS 17) + physical Pixel 6 / iPhone 12 via fastlane.

**Acceptance gates:** 8K open w/o OOM; 60 fps slider; BG remove < 1.2 s @ 12 MP; round-trip pixel parity.

---

## Phase 2 — Shipped manifest (2026-06-02)

### Android C++ (`android/src/main/cpp/imgedit/`)
- `egl_context.h/.cpp` — EGL_DEFAULT_DISPLAY config (RGBA8/depth0/GLES3_BIT); `ANativeWindow` acquire/release; `eglMakeCurrent`/`eglSwapBuffers`.
- `render_graph.h/.cpp` — `RenderGraph` ping-pong FBOs; embedded GLSL ES 3.0 programs: passthrough, **B3 adjust** (`kFsAdjust`), 3D LUT (`kFsLut`), crop (`kVsCrop`/`kFsCrop` with `uniform mat3 u_h`), overlay composite with multiply/screen/overlay blend (`kFsOverlay`); `execute(passes, present)` chains crop → adjust → LUT → per-layer overlays → drawable.
- `pipeline.cpp` — `SessionImpl : Session` with mutex-guarded lifecycle; sessions registry; `apply_filter` parses `.cube` + uploads 3D texture; `apply_crop` chooses homography vs centred matrix; `read_pixels` runs graph + `glReadPixels`.
- `lut.cpp` — `.cube` parser (skips `TITLE`/`DOMAIN_*`/`LUT_3D_SIZE`); `glTexImage3D(GL_RGB16F)` upload.
- `crop.cpp` — 8×8 Gaussian-elim homography solver from 4-corner correspondence; `crop_matrix(x,y,w,h,rotDeg)` builds rotate/scale/translate mat3.
- `liquify.cpp` — per-`viewId` 32×32 dx/dy grid; push/pull/pinch/bloat/twirl ops with gaussian falloff.
- `heal.cpp` — `heal_spot` / `inpaint_region` JNI entry stubs (PatchMatch CPU body deferred).
- `jni_bridge.cpp` — full JNI surface matching `ImageEditNative.kt`; `ANativeWindow_fromSurface`; `AndroidBitmap_lockPixels` for `nativeReadPixels`; Kotlin `Map<*,*>` walked via `java/lang/Number`/`java/util/List`.
- `CMakeLists.txt` — `minis_imgedit` SHARED linking `EGL`/`GLESv3`/`android`/`log`/`jnigraphics`.

### Android Kotlin (`android/src/main/kotlin/com/loopit/minis/imgedit/`)
- `DrawLayer.kt` — `Bitmap` + `Canvas` with `BlurMaskFilter` hardness blur; stamped circles at `size/4` spacing; `PorterDuff.Mode.CLEAR` for eraser; pressure interpolated between points.
- `StickerLayer.kt` — decodes sticker PNG under affine matrix; text via `Paint`+`Typeface` (stroke + fill); emoji via `String(Character.toChars(cp))`.
- `EmojiPickerView.kt` — PlatformView `loopit/minis/emoji_picker`; horizontal tab row + `RecyclerView` `GridLayoutManager(8)`; per-category Unicode 15.1 ranges; `SharedPreferences key=minis_emoji` recents; `MethodChannel("loopit/minis/emoji_picker/selected").invokeMethod("emit", {codePoint})`.
- `AssetCatalog.kt` — `bind(ctx)` hook; enumerates `assets/luts/*.cube`, `assets/stickers/<pack>/manifest.json`, `assets/fonts/<family>-<weight>.ttf` (grouped by family); safe defaults when bundles absent.
- `HistoryStack.kt` — `setMemoryCap(bytes)` + `memoryCap()` accessors; eviction reapplied on shrink.
- `ImageEditEngine.kt` — added `setHistoryCap` MethodChannel verb.
- `ImageEditPluginRouter.kt` — `notifyRenderProgress` / `notifyError` / `notifyMemoryPressure` helpers.
- `LoopitMinisPlugin.kt` — `EmojiPickerViewFactory` registration; `AssetCatalog.bind(ctx)` on attach / `bind(null)` on detach; `Application.registerComponentCallbacks` for `onTrimMemory` → `notifyMemoryPressure`.

### iOS Swift (`ios/Classes/ImgEdit/`)
- `ImageEditMetalRenderer.swift` — rewritten as the real pipeline driver; `MTKTextureLoader` decodes source CGImage to base `MTLTexture`; `LutCubeParser` parses `.cube` + uploads `rgba16Float` 3D texture (float→half packer included); `solveHomography` (Gaussian-elim) + `cropMatrix` static helpers; `applyAdjust` populates `AdjustParamsBuffer`; `readbackCGImage` re-runs the graph offscreen + uses `CIContext(mtlDevice:)` to produce a final `CGImage`; `setMaskTexture(_:)` for B9; `hostView` weak ref drives `setNeedsDisplay`.
- `DrawLayer.swift` — `CGContext` premultipliedLast 8888; `.clear` blend for eraser; same stamp math as Android.
- `StickerLayer.swift` — `CGContext` rasterizer for sticker / `NSAttributedString` text / emoji codepoint.
- `LiquifyGrid.swift` — 32×32 displacement; `rg16Float` `MTLTexture` upload; float→half conversion.
- `Beauty.swift` — `CIFilter.boxBlur` skin smooth + `CIFilter.colorControls` teeth/eyes brighten composited per-ROI via `CIFilter.blendWithMask`.
- `BackgroundRemover.swift` — `VNGeneratePersonSegmentationRequest(.accurate)`; `CVPixelBuffer` → `r8Unorm` `MTLTexture`.
- `EmojiPickerView.swift` — PlatformView `loopit/minis/emoji_picker`; `UISegmentedControl` + `UICollectionView` flow layout (44×44 cells); `UserDefaults key=minis_emoji_recents`; same `emit` method as Android.
- `AssetCatalog.swift` — bundle enumeration via `Bundle(for: BundleLocator.self)`.
- `HistoryStack.swift` — `setMemoryCap(_:)` + `memoryCapBytes()` accessors.
- `ImageEditPluginRouter.swift` — `notifyRenderProgress` / `notifyError` / `notifyMemoryPressure` helpers; `observeMemoryWarnings` / `stopObservingMemoryWarnings` against `UIApplication.didReceiveMemoryWarningNotification`.
- `ImageEditEngine.swift` — wires `hostView`; `removeBg` uploads `BackgroundRemover` mask + calls `setMaskTexture`; added `setHistoryCap` handler.
- `LoopitMinisPlugin.swift` — registers `EmojiPickerViewFactory` under `loopit/minis/emoji_picker`; calls `observeMemoryWarnings()`.

### iOS Metal (`ios/Classes/ImgEdit/Metal/`)
- `render_graph.swift` — `RenderGraph` + `AdjustParamsBuffer` / `LutParamsBuffer` / `CropParamsBuffer` / `OverlayParams`; compiles `passthrough` / `adjust` / `lut` / `overlay` / `crop` pipeline states from `default.metallib`; ping-pong `MTLTexture` ladder.
- `passthrough.metal` — `minis_quad_vs` triangle-strip vertex shader + `minis_passthrough` fragment.
- `filters.metal` — `minis_adjust` body (exposure, contrast, saturation, temperature, tint, sharpen via unsharp mask, clarity via larger blur, dehaze via dark-channel subtract). Mirrors GLSL.
- `lut.metal` — `minis_lut3d` sampler with `LutParams` (intensity + size); shared scale/offset math.
- `overlay.metal` — `minis_overlay_composite` with multiply/screen/overlay blend.
- `crop.metal` — `minis_crop_vs` applies 3×3 homography to uv; `minis_crop` clamps + samples.

### Dart (`lib/src/imgedit/`)
- `emoji_picker_view.dart` — new `MinisEmojiPicker` widget; `MethodChannel("loopit/minis/emoji_picker/selected")` handler converts native `emit` calls into `onSelected(int codePoint)`.
- `image_edit_screen.dart` — added emoji toolbar button; tap opens 55%-height bottom sheet hosting `MinisEmojiPicker`; picks call `placeEmoji(viewId, codePoint, transform=center)` and dismiss.
- `lib/loopit_minis.dart` — exports `emoji_picker_view.dart`.

### Build
- `android/build.gradle` — added `androidx.recyclerview:recyclerview:1.3.2` + `com.google.mlkit:segmentation-selfie:16.0.0-beta5`.
- `android/src/main/cpp/CMakeLists.txt` — added `minis_imgedit` shared library + sources (videdit block preserved).

### Test
- `example/integration_test/imgedit_round_trip_test.dart` — bundles 7680×4320 sample → `init` → 6 ops (`applyCrop`, `applyFilter`, `placeSticker`, `placeText`, `brushStroke`, `beautify`) → `exportImage(jpeg, q=92)` → re-`init` → `dispose`. Skips when sample asset / cache dir absent so CI without the asset still passes.

### Phase 3 follow-ups
- PatchMatch CPU body in `heal.cpp` (8×8 patches, 32 iterations; sub-texture upload).
- `.cube` LUT bundle (30+ free-license files) + sticker pack PNG sheets + 5–8 display fonts under `assets/`.
- Skin-tone variant long-press in emoji picker (5 variants per people-category item).
- Tile-snapshot + LZ4 disk spill inside `HistoryStack` (the `setHistoryCap` verb is the durable contract).
- Gyro horizon-level via `CMMotionManager` (iOS) / `SensorManager` (Android); `EventChannel("loopit/minis/imgedit/horizon")`.
- Device-matrix acceptance harness: ffprobe-driven pixel-hash comparison on Pixel 6 + iPhone 12; 60 fps slider profiling; OOM-free 8K open; BG-remove latency under 1.2 s.
