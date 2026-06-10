# Changelog

## 0.1.0 — 2026-06-03 — Native enterprise migration

Full conversion of `loopit_minis` to a pure-native plugin. The Dart side
shrinks to thin `MethodChannel` + `EventChannel` + `PlatformView` wrappers;
every media / system surface (camera, image editor, video editor, audio
engine, media I/O, pickers, player, permissions, paths, device info,
wakelock, share) is implemented in Kotlin + Swift + C/C++ (FFmpeg, OpenGL
ES, Metal, MediaCodec, VideoToolbox, CameraX, AVFoundation, ExoPlayer,
AVPlayer, AAudio, AVAudioEngine, MLKit, Vision, RNNoise alternatives
through platform `NoiseSuppressor` / `VoiceProcessingIO`, LAME, WSOLA).

### Removed pub dependencies (host must remove any direct references)

`camera`, `pro_image_editor`, `emoji_picker_flutter`, `pro_video_editor`,
`video_trimmer`, `video_compress`, `video_thumbnail` (+ the
`video_thumbnail_mock` workspace package and the matching
`dependency_overrides:` block), `audio_waveforms`, `audio_session`,
`image_picker`, `file_picker`, `video_player`, `path_provider`, `path`
(direct), `permission_handler`, `device_info_plus`, `wakelock_plus`,
`phosphor_flutter`.

### Minimum OS versions

- Android: **8.0 (API 26)**. HDR / multi-cam features gate at API 33+.
- iOS: **14.0**. Person-segmentation and a handful of HDR features gate
  at iOS 15+.

### Channel surface (stable)

| MethodChannel | EventChannels | PlatformView |
| --- | --- | --- |
| `loopit/minis/camera` (legacy alias: `com.buzzit.social/minis_native_camera`) | `…/state`, `…/audio_levels`, `…/metadata`, `…/analysis`, `…/frames` | `loopit/minis/camera/preview`, `…/preview_secondary` |
| `loopit/minis/imgedit` | `…/state` | `loopit/minis/imgedit/canvas` |
| `loopit/minis/emoji_picker` | `…/selected` (via per-instance MethodChannel) | `loopit/minis/emoji_picker` |
| `loopit/minis/videdit` | `…/progress`, `…/state` | `loopit/minis/videdit/preview` |
| `loopit/minis/audio` | `playerEvents`, `levels`, `state`, `progress` | `loopit/minis/audio/waveform` |
| `loopit/minis/picker` | — | — |
| `loopit/minis/permissions` | `…/events` | — |
| `loopit/minis/paths` | — | — |
| `loopit/minis/player` | `…/events/<playerId>` | `loopit/minis/player` |
| `loopit/minis/device` | `…/thermal` | — |
| `loopit/minis/wakelock` | — | — |
| `loopit/minis/share` | — | — |
| `loopit/minis/telemetry` | `…/events` | — |

Dart-side entry points: `MinisCamera`, `MinisImageEditor`, `MinisVidEdit`,
`MinisAudioRecorder` / `MinisAudio*`, `NativePicker`, `NativePaths`,
`NativePermissions`, `NativeVideoPlayerController` / `NativeVideoPlayerView`,
`NativeDeviceInfo`, `NativeWakelock`, `NativeShare`, `MinisTelemetry`.

### Breaking changes — host migration checklist

1. **Remove forbidden deps** from your app's `pubspec.yaml` and run
   `flutter pub get`. The plugin's own `pubspec.yaml` only declares
   `flutter` + `get`. Any reference to a package in the removed list
   above will be flagged by the `lockfile-guard` job in
   `.github/workflows/build.yaml`.
2. **Replace API call sites** as follows:
   - `package:camera` → `MinisCamera` / `CameraPreviewView`.
   - `pro_image_editor` → `MinisImageEditor.openFromFile / openFromMemory`.
   - `emoji_picker_flutter` → `MinisEmojiPicker` widget.
   - `pro_video_editor` / `video_trimmer` / `video_compress` /
     `video_thumbnail` → `MinisVidEdit` engine + `VidEditPreviewView`.
   - `audio_waveforms` → `MinisAudioRecorder` / `MinisWaveform` widget
     (the package's `PlayerController` API has a drop-in shim).
   - `audio_session` → `AudioSession.instance.configure(...)` /
     `setActive(...)` shim with identical method signatures.
   - `image_picker` / `file_picker` → `NativePicker.pickImage / pickVideo
     / pickMedia / pickFile / saveToGallery`.
   - `video_player` → `NativeVideoPlayerController` +
     `NativeVideoPlayerView(controller: c, fit: …, hdrTonemap: true)`.
   - `path_provider` / `path` → `NativePaths.cacheDir / appSupportDir /
     documentsDir / externalDir / tempFile / join / extension / basename`.
   - `permission_handler` → `NativePermissions.check / request /
     requestMulti / openSettings` with
     `PermissionStatus { granted, denied, permDenied, restricted }`.
   - `device_info_plus` → `NativeDeviceInfo.info / thermal / battery /
     thermalStream`.
   - `wakelock_plus` → `NativeWakelock.enable / disable`.
   - `phosphor_flutter` → Material `Icons.*` (the audit mapped every
     glyph in use; no bundled font needed).
3. **AndroidManifest.xml — host app** (`example/android/app/src/main/`):

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>
<uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<!-- Legacy storage (API ≤ 28) -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
                 android:maxSdkVersion="32"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
                 android:maxSdkVersion="28"/>

<uses-feature android:name="android.hardware.camera" android:required="true"/>
<uses-feature android:name="android.hardware.microphone" android:required="true"/>
```

Inside `<application>`, register the plugin's FileProvider:

```xml
<provider
  android:name="androidx.core.content.FileProvider"
  android:authorities="${applicationId}.loopit_minis.fileprovider"
  android:exported="false"
  android:grantUriPermissions="true">
  <meta-data
    android:name="android.support.FILE_PROVIDER_PATHS"
    android:resource="@xml/loopit_minis_file_paths"/>
</provider>
```

Drop the matching xml at
`example/android/app/src/main/res/xml/loopit_minis_file_paths.xml`:

```xml
<paths xmlns:android="http://schemas.android.com/apk/res/android">
  <cache-path           name="loopit_minis_cache"      path="."/>
  <files-path           name="loopit_minis_files"      path="."/>
  <external-cache-path  name="loopit_minis_ext_cache"  path="."/>
  <external-files-path  name="loopit_minis_ext_files"  path="."/>
</paths>
```

Bump `compileSdk` to **34** and `minSdk` to **26** in
`android/app/build.gradle`.

4. **iOS Info.plist usage strings** (`example/ios/Runner/Info.plist`):

```xml
<key>NSCameraUsageDescription</key>
<string>Capture photos and video.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Record audio for video.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Pick media from your library.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Save edited media to your library.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Tag photos with location.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Tag photos with location.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>Transcribe captions on-device.</string>
```

iOS deployment target must be **14.0** or newer (set in
`example/ios/Podfile` `platform :ios, '14.0'` and in
`Runner.xcodeproj` build settings).

5. **FFmpeg artefacts** — the video editor only fully activates after the
   FFmpeg cross-build runs once. Two options:
   - **CI**: trigger
     `.github/workflows/ffmpeg-build.yml` (`workflow_dispatch`),
     download the `minis-ffmpeg-bundle` artefact, untar into the
     plugin root. The build matrix in
     `.github/workflows/build.yaml` caches the artefact between runs
     keyed by the hash of every `build_*.sh` script + the NDK / Xcode
     version.
   - **Local**: `bash android/ffmpeg/build_android.sh` and
     `bash ios/ffmpeg/build_ios.sh`. Produces
     `android/src/main/jniLibs/<abi>/*.so` and
     `ios/Frameworks/FFmpeg.xcframework`.

6. **MP3 encoder vendor** (audio recorder MP3 path only) — run
   `bash android/scripts/fetch_lame.sh` and
   `bash ios/scripts/fetch_lame.sh` once. AAC / WAV / Opus paths work
   without LAME.

### Telemetry

Off by default. Host opts in by calling
`MinisTelemetry.instance.enable(sink: TelemetrySink.log)` or
`.stream` and subscribing to `MinisTelemetry.instance.events`. Events
carry only structural fields (operation, duration, codec, thermal state,
result code); no file paths, URIs, byte content, or any host identifiers.

### Acceptance

`flutter pub deps --no-dev` must list zero of the removed packages.
`flutter analyze` must be clean. Integration tests in
`example/integration_test/` (reel capture → trim → export, story photo →
edit → post, feed image-multi → post) must pass on an Android emulator
and an iOS simulator.
