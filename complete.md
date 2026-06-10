# Minis Plugin — Real Shipped Work Log

> **2026-06-04 reset.** The prior 141 KB `complete.md` (preserved as
> `complete.aspirational.md`) declared 64/64 tasks done and 18 pubs
> killed. Disk audit on 2026-06-04 showed:
>
> - `pubspec.yaml` still lists all 17 supposedly-killed deps
>   (`pro_image_editor`, `pro_video_editor`, `camera`, `audio_session`,
>   `audio_waveforms`, `video_thumbnail`, `video_trimmer`,
>   `video_compress`, `image_picker`, `file_picker`, `video_player`,
>   `permission_handler`, `path_provider`, `device_info_plus`,
>   `wakelock_plus`, `phosphor_flutter`, `emoji_picker_flutter`).
> - `lib/src/native/` does not exist.
> - Android Kotlin: only flat `com.loopit.minis` package with 4 files
>   (camera bridge + preview view + preview player + plugin). No
>   `camera/`, `imgedit/`, `videdit/`, `audio/`, `native/` sub-packages.
> - Android cpp: only `audio/lame_README.md` and
>   `imgedit/shaders/README.md`. Zero `.c`, `.cpp`, `.glsl`, `.metal`.
> - iOS: only `Classes/LoopitMinisPlugin.swift`,
>   `Classes/MinisPreviewPlayer.swift`,
>   `Classes/ImgEdit/Metal/README.md`. No camera, imgedit, videdit,
>   audio, or native Swift sources.
> - `example/integration_test/` does not exist.
> - `.github/workflows/` does not exist.
>
> Conclusion: the prior tracking file documented the *plan*, not the
> *code*. Use `complete.aspirational.md` as design notes; this file is
> the real ledger going forward.

## Shipped (verified on disk)

_Nothing yet against the new ledger. The pre-existing Android camera
bridge described in the audit section below is treated as legacy and
will be migrated to the `camera/` package during A1–A2 redo._

## Audit snapshot (2026-06-04)

### A — Native Camera Engine (Android-only partials, iOS = 0)

| ID | Subject | Status | Notes |
| --- | --- | --- | --- |
| A1 | Skeleton + channels + EventChannels + PlatformView | 🟡 partial | Flat package, channel `com.buzzit.social/minis_native_camera` (non-convention), no `state`/`audio_levels`/`metadata`/`analysis` EventChannels |
| A2 | Preview view + `init`/`dispose` returning capabilities | 🟡 partial | PlatformView OK; uses `warmUp`+`bind` flow, no capabilities payload |
| A3 | Photo JPEG + RAW/DNG + EXIF | 🟡 partial | JPEG only |
| A4 | Single-clip recording | 🟢 real | Android only; no state events |
| A5 | Pause/resume/finalize merge | ⏳ pending | |
| A6 | Manual ISO/shutter/WB/focus/EV/zoom/flash + metadata stream | 🟡 partial | Zoom + torch only |
| A7 | HDR 10-bit | ⏳ pending | |
| A8 | Slow-mo + time-lapse | ⏳ pending | |
| A9 | Multi-cam PiP | ⏳ pending | |
| A10 | Thermal/storage guards + crash-safe recovery | ⏳ pending | |
| A11 | Permissions channel | ⏳ pending | |
| A12 | Cut over capture screen, kill `camera:` pub | ⏳ pending | Dart still imports `package:camera` |

iOS A1–A12: ⏳ all pending (no camera Swift code exists).

### B — Native Image Editor: ⏳ all pending (only README skeletons).
### C — Native Video Editor: ⏳ all pending (only README skeleton in audio LAME doc).
### D — Native Audio Engine: ⏳ all pending.
### E — Native Media I/O + Sys: ⏳ all pending.
### F — Cross-cutting (CI/changelog/telemetry/integration): ⏳ all pending.

## Pub-dep kill-tracker (verified on disk)

Killed: **none**.

Remaining (must be removed before B/C/D/E shipping closes):
`camera`, `pro_image_editor`, `emoji_picker_flutter`, `pro_video_editor`,
`video_trimmer`, `video_compress`, `video_thumbnail` (+ mock override),
`audio_waveforms`, `audio_session`, `image_picker`, `file_picker`,
`video_player`, `path_provider`, `path`, `permission_handler`,
`device_info_plus`, `wakelock_plus`, `phosphor_flutter`.

`get` (state mgmt) kept by design.
