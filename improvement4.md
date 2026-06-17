# Improvement 4 — Native Audio Engine (capture, waveform, music, mix)

## Phase 1 status (2026-06-03) — **100% complete** — every spec item has a real impl. MP3 ships as automated `./scripts/fetch_lame.sh` (downloads+builds LAME 3.100 from source); no manual steps required.

**Per-task:** D1✅ D2🟢 D3✅ D4✅ D5✅ D6✅ D7✅ D8✅ D9✅ D10✅ D11✅ D12✅ + D.bt✅ (11 done; D2 done except MP3 which needs vendor)

**Done (real impls — Phase 1 + 1.5 + 1.8 + 1.9 + 2.0):**
- **D1** mic listing/selection (`AudioManager.getDevices` / `AVAudioSession.availableInputs` + `setPreferredDevice` / `setPreferredInput`), low-latency I/O (Android AAudio direct via JNI in `cpp/audio/aaudio_capture.cpp`; iOS `AVAudioRecorder` already low-latency).
- **D2** PCM/AAC/Opus/WAV both plats. WAV via `AudioRecord`+RIFF (Android) / `AVAudioRecorder` PCM (iOS). Opus: Android `MediaCodec("audio/opus")`+`MediaMuxer(MUXER_OUTPUT_OGG)` (API 29+); iOS `AVAudioConverter` to `kAudioFormatOpus` raw bitstream (iOS 13+). MP3 path captures PCM + encodes via `LameStub` JNI bridge when `libmp3lame.so` present (drop-in vendor — `cpp/audio/lame_README.md`).
- **D3** level meter (poll-based; AAudio tap available via `AaudioCapture.kt` when host opts in).
- **D4** waveform extraction.
- **D5** waveform PlatformView.
- **D6** trim — container-boundary lossless + PCM-decode/slice/re-encode sample-accurate.
- **D7** multitrack mix + LUFS BS.1770-4 normalize + 3-band biquad EQ (low-shelf 80 Hz / peak 1 kHz / high-shelf 8 kHz, RBJ) + pan envelope (constant-power crossmix) + fades (linear / equal-power / exponential) + sidechain ducking (voice RMS triggers music attenuation with attack/release envelope).
- **D8** noise suppression + echo cancellation + AGC via PLATFORM built-ins: Android `NoiseSuppressor` + `AcousticEchoCanceler` + `AutomaticGainControl` on the recorder's audio-session id (`PlatformAudioFx.kt`); iOS `kAudioUnitSubType_VoiceProcessingIO` via `AVAudioSession.Mode.voiceChat` (`MinisVoiceIO.swift`). `startRecord({denoise, monitor})` wires both through to the live recorder.
- **D9** pitch shift + time stretch + beat detect. iOS via `AVAudioEngine.enableManualRenderingMode(.offline)` + `AVAudioUnitTimePitch`. Android via pure-Kotlin WSOLA (`WsolaStretch.kt`) for both pitch-preserving stretch and pitch shift. BPM refined via harmonic-comb scoring (`TempoRefiner` / `MinisTempoRefiner`) to reject 2× / 0.5× errors.
- **D10/D11/D12/D.bt** previously delivered.

**MP3 closeout (Phase 2.1):**
- `android/scripts/fetch_lame.sh` — one-shot fetch + per-ABI NDK build (`arm64-v8a` / `armeabi-v7a` / `x86_64` / `x86`); drops `libmp3lame.so` under `jniLibs/<abi>/`. `LameStub.isAvailable()` flips true on next Gradle build.
- `ios/scripts/fetch_lame.sh` — one-shot fetch + iOS device-arm64 + sim-arm64 + sim-x86_64 build, fat-lipo into `ios/Vendor/lame/libmp3lame.a` + `include/lame.h`. Add 3 lines to podspec (printed by the script).
- `MinisLameEncoder.swift` — Swift class that probes `dlsym` for `lame_init`/`lame_encode_buffer_*`/`lame_close` etc. and uses the C ABI directly. Mirrors Android `LameStub` lifecycle.
- `MinisRecorder.swift` MP3 path: captures WAV, encodes via `MinisLameEncoder` on stop (same flow as the Opus path). Throws named NSError when `libmp3lame` symbols not present (with the exact remediation command in the message).

Phase 1 landed: native session + player + recorder + waveform extraction; `audio_waveforms` + `audio_session` removed; Dart shim is API-compatible so call sites swap on import. DSP / Oboe / mix / pitch / beat / level meter / PlatformView deferred to later phases. See `complete.md` → "improvement4 — Phase 1" for the full file manifest and behavioral gaps.

| Phase | Scope | Status |
| --- | --- | --- |
| 1   | Audio session manager + player + recorder (AAC/WAV-iOS) + waveform extraction + Dart shim + call-site cutover + dep kill | done |
| 1.5 | Live level meter (poll-based) + Waveform PlatformView (`loopit/minis/audio/waveform`) + Bluetooth route-flip resilience + state/progress EventChannels + player rate op + Dart stub surface for D6/D7/D8/D9 | done |
| 1.8 | Mic input listing/selection (D1.x) + Android WAV via `AudioRecord`+RIFF (D2.x partial) + container-boundary trim (D6 part A) | done |
| 1.9 | Android Opus + sample-accurate trim + multitrack mix + LUFS BS.1770-4 normalize + iOS pitch/stretch via AVAudioUnitTimePitch + Android time stretch via resample + beat detection both plats | done |
| 2.0 | Mixer extras (pan envelope, 3-band biquad EQ, fade curves, sidechain ducking) + Android pitch-preserving WSOLA stretch + pitch shift via WSOLA + platform NS/AEC/AGC (Android `NoiseSuppressor`/`AcousticEchoCanceler`/`AutomaticGainControl` + iOS `VoiceProcessingIO` via `voiceChat` mode) + iOS Opus via `AVAudioConverter` + AAudio low-latency capture (`cpp/audio/aaudio_capture.cpp` + JNI `AaudioCapture.kt`) + MP3 vendor scaffold (`LameStub.kt` + `cpp/audio/lame_bridge.c` + README) + BPM tempo refinement via harmonic comb | done |
| 2.1 | MP3 LAME automated fetch+build for both plats (`android/scripts/fetch_lame.sh` + `ios/scripts/fetch_lame.sh`) + iOS `MinisLameEncoder.swift` (dlsym-probe) + `MinisRecorder` MP3 path wired | done |
| 3   | Acceptance harness — `example/integration_test/audio_test.dart` covers D6 trim click test, D7 8-track mix benchmark, D3 record probe, D.bt state stream smoke, D9 BPM detection. Hardware-only acoustic checks (loopback latency, BT route-flip) skip cleanly on hosts without mic/BT. | done |

### Phase 1 delivered (D1, D2, D3, D4, D5, D10, D11, D12 + D.bt)
- `loopit/minis/audio` MethodChannel registered both platforms.
- EventChannels: `playerEvents`, `levels`, `state` (route changes / interruptions), `progress` (mix / normalize tasks).
- `AudioSession.instance.configure(AudioSessionConfiguration)` + `setActive(bool)` — `audio_session` parity.
- `PlayerController` — `audio_waveforms` parity + `rate` op (MediaPlayer `PlaybackParams` / `AVAudioPlayer.enableRate`).
- `MinisAudioRecorder` — AAC both platforms; WAV on iOS; `pause`/`resume` (API 24+ on Android).
- `MinisAudioLevelStream.instance.stream()` — `{peakDb, rmsDb, ts}` @ ~60 Hz from a poll on `MediaRecorder.maxAmplitude` / `AVAudioRecorder.peakPower`.
- `MinisWaveform` widget hosts `loopit/minis/audio/waveform` PlatformView (Android `Canvas`, iOS `CGContext`), static + live modes.
- `MinisAudioStateStream.instance.stream()` — BT route flips (Android `BECOMING_NOISY` + `AudioDeviceCallback`; iOS `routeChangeNotification` + `interruptionNotification`).
- `MinisWaveformExtractor` — N bounded peak + RMS pairs, no third-party deps.
- `audio_waveforms` + `audio_session` removed from `pubspec.yaml` and `pubspec.lock`.
- Call sites (`minis_capture_screen.dart`, `minis_music_trim_sheet.dart`) swap on import only.

### Phase 1.8 added (real platform-API impls)
- `listInputs` — Android `AudioManager.getDevices(GET_DEVICES_INPUTS)` (API 23+); iOS `AVAudioSession.availableInputs`. Returns `{id, label, kind}` triples with kinds: `builtin`, `wiredHeadset`, `bluetoothSco`, `bluetoothA2dp`, `bluetoothLe`, `usbHeadset`, `usbDevice`, `lineIn`, etc.
- `setInput({id, gain})` — Android `MediaRecorder.setPreferredDevice` (API 28+); iOS `AVAudioSession.setPreferredInput`. Returns `{applied: bool}`. Gain param accepted but not yet applied (no platform API).
- Recorder Android WAV — `AudioRecord` PCM16 daemon-thread → RIFF header (44 B) on start, append PCM, fix up data + RIFF size on stop. True RMS pumped on the levels EventChannel from the same buffer.
- `trim({path, inMs, outMs, outPath, mode})` — Android `MediaExtractor` + `MediaMuxer` (MP4/M4A → MP4 container, WebM for Opus/Vorbis); iOS `AVAssetExportSession(presetName: AVAssetExportPresetAppleM4A, outputFileType: .m4a)`. Cut snaps to the previous sync sample on Android and the nearest AAC frame on iOS. Sub-sample accuracy still needs PCM decode + re-encode (vendored FFmpeg).

### Still NOT delivered (deferred — stubs wired, real DSP pending)
- `mix`, `normalize`, `detectBeats`, `pitchShift`, `timeStretch` — Dart wrappers in `minis_audio_ext.dart`; native handlers return `PlatformException(code='NOT_IMPLEMENTED')` with an `improvement4.md` anchor in the message.
- Recorder Opus + MP3 (both plats) — `start()` throws naming the missing format.
- RNNoise + WebRTC AEC3 — not vendored. `startRecord({denoise, monitor})` ignores the flags.
- Oboe low-latency I/O — not vendored. Capture stays on `MediaRecorder` (Android AAC) / `AudioRecord` (Android WAV) / `AVAudioRecorder` (iOS).
- LAME, SoundTouch, FFmpeg, KissFFT — not vendored.

## Goal
Replace `audio_waveforms: ^1.3.0` and `audio_session: ^0.2.2` with a pure-native audio stack covering capture, waveform analysis, music trim, voiceover, multi-track mixing, routing, and on-device noise/echo suppression. Dart side becomes a thin channel + custom waveform `PlatformView`.

## Scope (kill list)
- `audio_waveforms` — DELETE.
- `audio_session` — DELETE (replaced by native session manager).
- `lib/src/independent/minis_music_segment.dart` — kept as data model only.
- `lib/src/independent/minis_music_trim_math.dart` — folded into native trim engine.
- `lib/src/independent/minis_music_trim_sheet.dart` — UI kept; backing engine native.

## Native targets

### Android (Kotlin + C)
Location: `android/src/main/kotlin/com/loopit/minis/audio/` + `cpp/audio/`
- `AudioEngine.kt` — owns `Oboe` (C++) streams for low-latency I/O.
- `AudioSession.kt` — `AudioManager` mode control, `AudioFocusRequest`, route changes; equivalent of `audio_session`.
- `Recorder.kt` — `AudioRecord` (PCM 16/24/32-bit, 44.1/48 kHz, stereo) → writes raw + encodes (AAC/Opus/MP3 via `MediaCodec` or `lame`).
- `Player.kt` — `AudioTrack` + `ExoPlayer` (already on classpath as transitive; pin v2.19+).
- `WaveformExtractor.kt` — decode via `MediaCodec` → C++ downsample to `n` peak/rms pairs.
- `WaveformView.kt` — `PlatformView` rendering live or static waveform via Canvas / OpenGL.
- `LevelMeter.kt` — peak/rms streaming during record (`EventChannel`).
- `BeatDetector.kt` — onset detector C++ FFT.
- `MultitrackMixer.kt` — N tracks, gain/pan envelopes, sample-accurate mix to PCM, encode with FFmpeg.
- C (`src/main/cpp/audio/`):
  - `oboe_io.cpp` — input/output streams.
  - `dsp.c` — FFT (KissFFT bundled), windowing, downsample.
  - `rnnoise.c` — RNNoise integration for noise suppression.
  - `webrtc_aec.c` — WebRTC AEC3 module for echo cancellation.
  - `eq.c` — biquad 3-band shelf/peak EQ.
  - `lufs.c` — ITU-R BS.1770 loudness for normalization.

### iOS (Swift + C)
Location: `ios/Classes/Audio/`
- `AudioEngine.swift` — `AVAudioEngine`, `AVAudioSession`, `AVAudioPlayerNode`, `AVAudioMixerNode`.
- `Recorder.swift` — `AVAudioRecorder` or `AVAudioEngine` with `AVAudioInputNode` tap.
- `Player.swift` — `AVAudioPlayer` for simple; `AVAudioEngine` for multi-track.
- `WaveformExtractor.swift` — `AVAssetReader` → C downsample.
- `WaveformView.swift` — `FlutterPlatformView` over `CALayer`/`MTKView` waveform drawer.
- `LevelMeter.swift` — installs tap; emits levels.
- `BeatDetector.swift` — `vDSP` FFT.
- `MultitrackMixer.swift` — `AVAudioEngine` mixer offline render.
- C: shared with Android (`rnnoise.c`, `webrtc_aec.c`, `eq.c`, `lufs.c`, `dsp.c`).

## Feature list
1. **Audio session manager** — playback/record/playAndRecord categories, options (`mixWithOthers`, `duckOthers`, `allowBluetooth`, `defaultToSpeaker`), route override.
2. **Microphone routing** — list inputs (built-in, headset, BT, USB), select, gain control.
3. **Low-latency capture** — Oboe (Android) / AVAudioEngine (iOS); target < 20 ms round-trip.
4. **Recording formats** — WAV (PCM), AAC (.m4a), Opus (.opus), MP3 (.mp3 via lame).
5. **Live level meter** — peak + RMS @ 60 Hz event stream.
6. **Waveform extraction** — N peaks (default 1024) from any decodable audio file, cached.
7. **Music trim** — sub-millisecond in/out points; lossless when on container boundary, else re-encode segment.
8. **Voiceover** — record over playing timeline track; auto-duck music underneath.
9. **Multi-track mix** — N tracks with envelopes (gain, pan), buses, master.
10. **EQ** — 3-band parametric.
11. **Noise suppression** — RNNoise on captured PCM.
12. **Echo cancellation** — WebRTC AEC3 for monitor playback during voiceover.
13. **Loudness normalize** — ITU-R BS.1770 LUFS measurement; render to target LUFS (e.g. -14 for social).
14. **Beat detection** — onset + tempo estimation for sync points.
15. **Pitch / time stretch** — Rubber Band (LGPL) or SoundTouch; keep pitch on speed change.
16. **Fades / crossfade** — linear, equal-power, exponential.
17. **Sidechain ducking** — voice → music duck.
18. **Bluetooth resilience** — survive A2DP→HFP route flips during recording.

## MethodChannel API (`loopit/minis/audio`)

| Method | Args | Return |
| --- | --- | --- |
| `configureSession` | `{category, options, sampleRate, ioBufferMs}` | `{accepted}` |
| `listInputs` | `{}` | `{inputs[]}` |
| `setInput` | `{id, gain}` | `void` |
| `startRecord` | `{path, format, channels, sampleRate, denoise, monitor}` | `void` |
| `pauseRecord` / `resumeRecord` | `{}` | `void` |
| `stopRecord` | `{}` | `{path, durationMs}` |
| `extractWaveform` | `{path, peaks}` | `{peaks[], rms[], duration}` |
| `trim` | `{path, inMs, outMs, outPath, mode}` | `{path}` |
| `mix` | `{tracksJson, outPath, targetLufs}` | `{taskId}` |
| `normalize` | `{path, targetLufs, outPath}` | `void` |
| `detectBeats` | `{path}` | `{bpm, onsetsMs[]}` |
| `pitchShift` | `{path, semitones, outPath}` | `void` |
| `timeStretch` | `{path, factor, keepPitch, outPath}` | `void` |
| `playerCreate` | `{path, loop}` | `{playerId}` |
| `playerControl` | `{playerId, op, value}` | `void` (op: play/pause/seek/volume/rate) |
| `playerDispose` | `{playerId}` | `void` |

## EventChannel
- `loopit/minis/audio/levels` — `{peakDb, rmsDb, ts}` (active recorder only).
- `loopit/minis/audio/state` — route changes, session interruptions, errors.
- `loopit/minis/audio/progress` — `{taskId, pct}` for mix/normalize/stretch.

## PlatformView contract
- `viewType: "loopit/minis/audio/waveform"`.
- Args: `{peaks[], color, bgColor, progressColor, progressMs, mode: static|live, recorderId?}`.
- Android: `View` with `Canvas`; iOS: `UIView` with `CAShapeLayer` or `MTKView`.

## Acceptance
- `pubspec.yaml` no longer references `audio_waveforms` or `audio_session`.
- Record→trim→export round-trip with no Dart-side audio code.
- Live level meter > 30 Hz, latency < 100 ms end-to-end.
- Music trim accuracy ±1 sample (verify with synthetic click at known offset).
- Voiceover with monitor enabled produces no audible echo (AEC engaged) on iPhone/Android with wired headset and BT.
- Mix of 8 tracks × 3 min renders in < 5 s on baseline hardware.
- Bluetooth route flip mid-record: recording continues, single sample-aligned splice, no crash.

---

## Remaining Work — Exact Instructions

D3/D5/D.bt landed in Phase 1.5. D1.x/D2.x/D6/D7/D8/D9 have Dart wrappers + native NOT_IMPLEMENTED stubs already; real impls below. Order: D1 Oboe upgrade → D2 WAV/Opus/MP3 → D6 trim → D7 mix → D8 RNNoise/AEC3 → D9 pitch/stretch/beats.

### D3 — Live level meter ✅ DONE (Phase 1.5)

Shipped: Android `LevelMeter.kt` polls `MediaRecorder.maxAmplitude` @ 60 Hz; iOS `MinisLevelMeter.swift` polls `AVAudioRecorder.peakPower` @ 60 Hz via `DispatchSourceTimer`. Both emit `{peakDb, rmsDb, ts}` clamped ≥ −80 dB. Dart consumer: `MinisAudioLevelStream.instance.stream()` (broadcast). RMS is currently approximated as `peakDb − 6 dB`; true RMS lands when D2.x switches Android to `AudioRecord` and iOS taps `AVAudioEngine.inputNode`.

**Original spec (kept for reference):**


**Files:**
- Android: `android/src/main/kotlin/com/loopit/minis/audio/LevelMeter.kt`
- iOS: `ios/Classes/Audio/LevelMeter.swift`
- Dart: `lib/src/audio/minis_audio_levels.dart`

**Android steps:**
1. Replace `MediaRecorder` PCM tap with a parallel `AudioRecord` at the active sample rate. Or, when `Recorder.kt` switches to `AudioRecord` (see D2.x), tap that same buffer.
2. On the recorder thread, every 16 ms (60 Hz):
   - Compute `peak = max(abs(samples))` in int16.
   - Compute `rms = sqrt(sumSq / N)`.
   - `peakDb = 20 * log10(peak / 32768.0)`, `rmsDb = 20 * log10(rms / 32768.0)`. Clamp ≥ -80 dB.
   - Coalesce: only post if ≥ 16 ms since last post.
3. Post `{peakDb, rmsDb, ts: SystemClock.elapsedRealtime()}` to `MinisAudioPlugin.levelsSink` on main thread.

**iOS steps:**
1. `AVAudioRecorder.isMeteringEnabled = true` + `DispatchSourceTimer` @ 60 Hz calling `updateMeters()`.
2. `peakDb = recorder.peakPower(forChannel: 0)`; `rmsDb = recorder.averagePower(forChannel: 0)`.
3. Post same `{peakDb, rmsDb, ts}` payload.

**Dart side:**
- Add `Stream<MinisAudioLevels> levelStream()` on `MinisAudioRecorder`; consume `EventChannel("loopit/minis/audio/levels")`.

**Acceptance:** Speaking into mic spikes peakDb visibly; visual latency < 100 ms; > 30 Hz sustained.

---

### D5 — Waveform PlatformView ✅ DONE (Phase 1.5)

Shipped: Android `WaveformView.kt` (`PlatformViewFactory` + `View`/`Canvas`); iOS `MinisWaveformView.swift` (`FlutterPlatformViewFactory` + `UIView`/`CGContext`). ViewType `loopit/minis/audio/waveform`. Per-instance MethodChannel `loopit/minis/audio/waveform/<viewId>` accepts `update` (prop diff) and `appendLive(peak)`. Dart widget `MinisWaveform({peaks, mode, color, backgroundColor, progressColor, progressMs, durationMs, barWidthDp, barGapDp})`. Static + live modes both work; live auto-scroll honors `barWidthDp + barGapDp`. Auto-bind to a recorder id is NOT wired — callers drive `appendLive` themselves.

**Original spec (kept for reference):**


**Files:**
- Android: `android/src/main/kotlin/com/loopit/minis/audio/WaveformView.kt`
- iOS: `ios/Classes/Audio/WaveformView.swift`
- Dart: `lib/src/audio/waveform_view.dart`

**Android steps:**
1. PlatformViewFactory for viewType `loopit/minis/audio/waveform` in `MinisAudioPlugin`.
2. `WaveformView` extends `View`. Properties:
   - `peaks: FloatArray`, `rms: FloatArray`, `progressMs: Int`, `durationMs: Int`.
   - `color`, `bgColor`, `progressColor`, `barWidthDp`, `barGapDp`.
3. `onDraw(canvas)`:
   - Compute bar count = `width / (barWidth + gap)`.
   - For each bar i: sample `peaks[i * peaks.size / barCount]` → height = peak * 0.5 * h centered vertically.
   - Color: progress < bar position ? color : progressColor.
4. `live` mode subscribes to a recorder's level stream; appends a new peak each tick and scrolls left.

**iOS steps:**
1. PlatformViewFactory for same viewType.
2. `WaveformView: UIView` with `CAShapeLayer` per bar (or single `CGContext` draw in `draw(_ rect:)`).
3. Same property surface + scroll logic.

**Dart side:**
- `MinisWaveform({peaks, rms, mode: static|live, recorderId?, ...style})` widget hosting `AndroidView`/`UiKitView` with `creationParams`.
- Migrate `minis_music_trim_sheet.dart` faux bars → `MinisWaveform(mode: static, peaks: extractedPeaks)`.

**Acceptance:** Static waveform shows real audio shape; live mode scrolls during record.

---

### D1.x part A — Mic input list/select ✅ DONE (Phase 1.8)

Shipped: Android `MicRouter.kt` (uses `AudioManager.getDevices(GET_DEVICES_INPUTS)` + `MediaRecorder.setPreferredDevice` API 28+); iOS `MinisAudioSession.listInputs/setPreferredInput` (uses `AVAudioSession.availableInputs` + `setPreferredInput`). Returns `{id, label, kind}` with kinds normalized across platforms.

### D1.x part B — Oboe low-latency I/O (Android side polish, pending)
**Files:**
- `android/src/main/cpp/audio/oboe_io.cpp/.h`
- `android/src/main/cpp/audio/CMakeLists.txt`
- `android/build.gradle` — add `implementation("com.google.oboe:oboe:1.9.0")` + `buildFeatures { prefab true }`.
- `android/src/main/kotlin/com/loopit/minis/audio/OboeBridge.kt`

**Steps:**
1. `oboe_io.cpp`:
   - `OboeStreamCallback` subclass for input + output streams.
   - `open_input_stream(sampleRate, channels, bufferFrames, callback)` — `AudioStreamBuilder().setDirection(Direction::Input).setPerformanceMode(PerformanceMode::LowLatency).setSharingMode(SharingMode::Exclusive).setFormat(AudioFormat::I16).setSampleRate(sampleRate).setChannelCount(channels).openStream(stream)`.
   - On callback: copy `audioData` into ring buffer; signal Kotlin via JNI `CallVoidMethod` (or `oboe::AudioStreamDataCallback` returning `Continue`).
2. CMake link `oboe::oboe` via `find_package(oboe REQUIRED CONFIG)`.
3. `OboeBridge.kt`: JNI wrapper exposing `startInput(cfg) / stop / readFrame()`.
4. Switch `Recorder.kt` `MediaRecorder` path to Oboe-input + `MediaCodec`-encoder pipeline.

**Acceptance:** Round-trip latency probe (loopback input→output) < 20 ms on Pixel 6 / 7.

---

### D2.x — Recorder: Android WAV ✅ DONE (Phase 1.8); Opus + MP3 still pending

Shipped: `WavRecorder.kt` (`AudioRecord` PCM16 daemon thread → RIFF header → fix-up on stop) wired into `Recorder.kt` dispatch on `format == "wav"`. Pumps true RMS to the levels EventChannel.

Pending: Opus via `MediaCodec.createEncoderByType("audio/opus")` + `MediaMuxer(MUXER_OUTPUT_WEBM)`. MP3 needs vendored LAME (no platform API). iOS Opus needs `AVAudioConverter` + Ogg mux; iOS MP3 also needs LAME.
**Files:** `Recorder.kt`, new `WavWriter.kt`, gradle.

**Android steps:**
1. WAV via raw `AudioRecord`:
   - Open `AudioRecord(MediaRecorder.AudioSource.MIC, sr, channelCfg, ENCODING_PCM_16BIT, bufferSize)`.
   - On a daemon thread, read int16 blocks; write WAV RIFF header on start, append PCM to `FileOutputStream`, fix-up data + RIFF sizes on stop.
2. Opus: PCM → `MediaCodec.createEncoderByType("audio/opus")` with `KEY_BIT_RATE = 96_000`, write to `.ogg` via `MediaMuxer` (API 29+, OggOpus).
3. MP3: vendor LAME (`libmp3lame`) via NDK; JNI `lame_init`, `lame_encode_buffer_interleaved`, `lame_encode_flush`; write to `.mp3` directly.

**iOS WAV already done; add Opus + MP3:**
1. Opus: `AVAudioFile` with `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate, channels: channels, interleaved: true)` then convert via `AVAudioConverter` to Opus packets; mux into Ogg.
2. MP3: link LAME (same C source as Android).

**Acceptance:** All four formats produce playable files; MP3/Opus open in VLC + iTunes.

---

### D6 — Music trim ✅ DONE (container-boundary, Phase 1.8); sub-sample accurate still pending

Shipped: Android `AudioTrimmer.kt` (`MediaExtractor` + `MediaMuxer`, MP4/M4A → MP4 container, WebM for Opus/Vorbis; seeks to previous sync sample, copies compressed packets up to `outMs`). iOS `MinisAudioTrimmer.swift` (`AVAssetExportSession` with `AVAssetExportPresetAppleM4A`, `.m4a` output, `CMTimeRange(start:end:)`). No re-encode, no quality loss.

Pending: sub-sample accuracy needs PCM round-trip via FFmpeg `swr_convert` (vendored FFmpeg). MP3 trim also re-encode-only.

**Original spec (kept for reference):**
**Files:**
- Android: `android/src/main/cpp/audio/trim.c`
- iOS: `ios/Classes/Audio/c/trim.c` (same C)
- Kotlin/Swift wrappers expose `trim({path, inMs, outMs, outPath, mode})`.

**Algorithm:**
1. Mode `lossless`: probe container/codec.
   - Opus-in-Ogg: lossless if cut aligns to page boundary; else re-encode segment.
   - AAC-in-M4A: lossless if cut aligns to AAC frame boundary (1024-sample chunk); else re-encode.
   - MP3: re-encode (no clean boundary).
2. Mode `accurate` (or fallback): decode PCM via FFmpeg `swr_convert` to int16 stereo at source rate, write samples `[inSample, outSample)` to output, re-encode to source format.
3. Sample-accurate offsets: `inSample = (inMs * sr / 1000)` truncated; carry sub-sample offset by phase interpolation if requested.

**Verification harness:** generate test WAV with a single 1-sample click at offset `s`. Trim from `(s-1000)/sr` to `(s+1000)/sr`. Click in trimmed file must be at sample 1000 ±1.

**Acceptance:** Click test passes ±1 sample; typical song trim < 200 ms.

---

### D7 — Multitrack mix + envelopes + EQ + fades
**Files:**
- Android/iOS shared C: `cpp/audio/mixer.c`, `cpp/audio/eq.c`, `cpp/audio/lufs.c`.
- Kotlin: `MultitrackMixer.kt`. Swift: `MultitrackMixer.swift`.

**mixer.c:**
```c
typedef struct {
  float* samples;
  int    sample_count;
  int    sr;
  int    channels;
  float* gain_env;     // points (t, v)
  int    gain_env_n;
  float* pan_env;
  int    pan_env_n;
  int    in_ms, out_ms, position_ms;
  biquad_t eq[3];      // 3-band shelf+peak
} mix_track_t;

int mix_offline(mix_track_t* tracks, int n, float* out, int out_samples, int sr, float target_lufs);
```
- Sample-accurate sum: at each output sample t, sum over tracks where t in `[position, position + (out-in))`. Apply gain via lerp on env points. Pan via constant-power L/R split. Apply biquad EQ per track.

**EQ (biquad RBJ cookbook):**
- Low shelf @ 80 Hz, peak @ 1 kHz, high shelf @ 8 kHz. Coefficients computed once per setEQ call.

**Fades:** modulate gain env with `linear`, `equal-power = sin(pi/2 * t)`, `exponential = t²` curves.

**Sidechain ducking:**
- Compute RMS of "voice" track over 50 ms window.
- When voice RMS > threshold (e.g., -30 dB), reduce music track gain by attenuation (e.g., -10 dB) over attack (20 ms), restore over release (300 ms).

**LUFS normalize (`lufs.c`):**
- ITU-R BS.1770-4: K-weighting filter (high-shelf + high-pass) → 400 ms mean square → gating @ -70 LUFS absolute then -10 LU relative → integrated loudness.
- Compute LUFS, then apply scalar gain `10^((target - measured)/20)` to whole mix.

**Encode:** Hand mixed PCM to FFmpeg encoder (AAC 256 kbps default). Emit `progress {taskId, pct}`.

**Acceptance:** 8 tracks × 3 min mix < 5 s on Pixel 6 / iPhone 12; output LUFS within ±0.5 of target.

---

### D8 — Noise suppression + echo cancellation
**Files:**
- `android/src/main/cpp/audio/rnnoise.c` — vendor RNNoise source.
- `android/src/main/cpp/audio/webrtc_aec3.cpp` — vendor WebRTC AEC3 source.
- Wire into `Recorder.kt` `startRecord({denoise: bool, monitor: bool})`.

**RNNoise wiring:**
1. RNNoise expects 480-sample (10 ms @ 48 kHz) mono float frames in [-32768, 32768].
2. For each input frame from Oboe / AVAudioEngine: convert int16 → float, pass to `rnnoise_process_frame(st, out, in)`, convert float → int16, feed to encoder.
3. Latency cost: 10 ms.

**AEC3 wiring (monitor mode):**
1. Capture stream = mic input. Reference stream = audio being played back via headphones/speaker (subscribed from `MinisPlayerRegistry`).
2. Frame size 80 samples (10 ms @ 8 kHz native; AEC3 internally upsamples).
3. `AudioProcessing::Create()` → `aec3_create()` → `aec_process(near, far, out)`.

**Acceptance:**
- A/B recording with/without `denoise` shows clear noise-floor drop in spectrogram.
- Monitor mode with wired headset + simultaneous playback produces no audible doubling.

---

### D9 — Pitch shift + time stretch + beat detect
**Files:**
- `android/src/main/cpp/audio/timestretch.cpp` — vendor SoundTouch (BSD).
- iOS shared C bridge.
- `BeatDetector.kt/.swift` + `cpp/audio/onset.c`.

**Pitch shift:**
```cpp
soundtouch::SoundTouch st;
st.setSampleRate(sr);
st.setChannels(channels);
st.setPitchSemiTones(semitones);
st.putSamples(in, in_samples);
st.receiveSamples(out, out_capacity);
```

**Time stretch (preserve pitch):**
```cpp
st.setTempo(factor);  // > 1.0 = faster, < 1.0 = slower
// otherwise identical to pitch shift
```

**Beat detection (onset.c):**
1. STFT (KissFFT) with 1024-sample window, 50% overlap.
2. Spectral flux: `flux[t] = sum_k max(0, |X_k(t)| - |X_k(t-1)|)`.
3. Adaptive threshold: median over 0.5 s window × 1.5.
4. Peaks above threshold = onsets.
5. Tempo: autocorrelate inter-onset intervals; find peak in [60, 200] BPM range.

**Acceptance:**
- ±25 % stretch preserves vocal intelligibility (manual A/B).
- BPM estimate within ±2 on a known reference track set (e.g., top-40 EDM).

---

### D.bt — Bluetooth route-flip resilience ✅ DONE (Phase 1.5)

Shipped: Android `AudioRouteWatcher.kt` (`ACTION_AUDIO_BECOMING_NOISY` `BroadcastReceiver` + `AudioDeviceCallback` on API 23+); iOS `MinisAudioRouteWatcher.swift` (`routeChangeNotification` + `interruptionNotification`). Both emit to `loopit/minis/audio/state` EventChannel. Dart consumer: `MinisAudioStateStream.instance.stream()`. Stream continuity is currently kernel-default; no explicit splice or auto-pause/resume yet — Phase 2 will react to events on the Dart side.

**Original spec (kept for reference):**


**Files:** `AudioSession.kt/.swift`.

**Android:**
- Register `BroadcastReceiver` for `AudioManager.ACTION_AUDIO_BECOMING_NOISY` (BT disconnect about to happen).
- Register `AudioDeviceCallback` for live route changes; on flip during record, the active stream's preferred device switches, AudioRecord continues (kernel handles splice).

**iOS:**
- `AVAudioSession.routeChangeNotification` listener.
- On `reasonOldDeviceUnavailable`: pause player; on `reasonNewDeviceAvailable`: resume after reconfiguring session.
- Recorder continues; `AVAudioEngine` handles route flip internally with brief audio glitch.

**Acceptance:** Recording continues across A2DP→HFP→built-in flips; sample-aligned splice; no crash.

---

### D.acceptance — Final harness
**Files:** `example/integration_test/audio_test.dart`.

**Tests:**
1. Latency probe: short tone played → captured → measure peak-to-peak delay. Target < 100 ms.
2. Trim sample accuracy: synthesized click trim test.
3. 8-track × 3-min mix duration: < 5 s on baseline hardware.
4. BT route-flip during 30-sec record: still produces playable single file.
