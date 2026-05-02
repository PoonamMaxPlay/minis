# Minis (`loopit_minis`)

Flutter package at **repo root** (sibling of `LoopIt/`). LoopIt depends on it via `path: ../minis`.

## Independent capture (no Retrytech)

The example app uses **`package:camera`** via `CameraPluginMinisEngine` and `MinisIndependentCaptureScreen`. Run on **Android or iOS** (device or emulator with camera):

```bash
cd minis/example
flutter pub get
flutter run
```

`MinisCaptureHost.openCapture()` is registered to the same screen for GetX demos.

## LoopIt reels UI (Retrytech, multi-clip, full tool rail)

The production reels stack in the main app still uses **Retrytech** today. To run that shell without the full app login flow:

```bash
cd LoopIt
flutter pub get
flutter run -t lib/minis_standalone_main.dart
```

## Video hub (`pro_video_editor`)

Open `MinisVideoHubPage.open(context)` from your UI when you want the editor hub (add a navigation action as needed).

## Tests

```bash
cd minis
flutter test
```
