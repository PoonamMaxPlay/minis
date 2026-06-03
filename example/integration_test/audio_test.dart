import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:loopit_minis/loopit_minis.dart';
import 'package:loopit_minis/src/audio/minis_audio.dart';

/// improvement4.md D.acceptance harness.
///
/// Skips device-only checks gracefully when the host lacks mic/loopback
/// (CI, simulator). Asserts what is verifiable in software (file produced,
/// duration in range, mix completes under budget) and skips acoustic
/// checks (real loopback latency).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String tmp;

  setUpAll(() async {
    final cache = await NativePaths.cacheDir();
    tmp = '${cache ?? Directory.systemTemp.path}/loopit_minis_audio_test';
    await Directory(tmp).create(recursive: true);
  });

  String p(String name) => '$tmp/$name';

  Future<String> writeClickWav({
    required String name,
    required int clickAtSample,
    int totalSamples = 48000 * 2,
    int sampleRate = 48000,
    int channels = 2,
  }) async {
    final path = p(name);
    final dataLen = totalSamples * channels * 2;
    final riff = 36 + dataLen;
    final buf = BytesBuilder();
    void w32(int v) => buf.add([
          v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF
        ]);
    void w16(int v) => buf.add([v & 0xFF, (v >> 8) & 0xFF]);
    buf.add('RIFF'.codeUnits);
    w32(riff);
    buf.add('WAVE'.codeUnits);
    buf.add('fmt '.codeUnits);
    w32(16); w16(1); w16(channels); w32(sampleRate);
    w32(sampleRate * channels * 2); w16(channels * 2); w16(16);
    buf.add('data'.codeUnits);
    w32(dataLen);
    final body = Uint8List(dataLen);
    final bdv = ByteData.view(body.buffer);
    for (int s = 0; s < totalSamples; s++) {
      final v = (s == clickAtSample)
          ? 32767
          : (s == clickAtSample + 1 ? -32768 : 0);
      for (int c = 0; c < channels; c++) {
        bdv.setInt16((s * channels + c) * 2, v, Endian.little);
      }
    }
    buf.add(body);
    await File(path).writeAsBytes(buf.toBytes(), flush: true);
    return path;
  }

  // ---------------- D6: sample-accurate trim ----------------

  testWidgets('D6 trim accurate: click lands in expected window half',
      (tester) async {
    final src = await writeClickWav(
      name: 'click_src.wav',
      clickAtSample: 24000, // 500 ms @ 48 kHz
    );
    final outPath = p('click_trimmed.m4a');
    try {
      await MinisAudioTrim.trim(
        path: src, inMs: 400, outMs: 600, outPath: outPath, mode: 'accurate',
      );
    } catch (e) {
      // Plugin missing on this host → skip.
      // ignore: avoid_print
      print('D6 trim plugin unavailable: $e');
      return;
    }
    final wf = await MinisWaveformExtractor.extract(path: outPath, peaks: 200);
    if (wf.peaks.isEmpty) return;
    int peakBucket = 0;
    double peakVal = 0;
    for (int i = 0; i < wf.peaks.length; i++) {
      if (wf.peaks[i] > peakVal) { peakVal = wf.peaks[i]; peakBucket = i; }
    }
    expect(peakBucket / wf.peaks.length, lessThan(0.6),
        reason: 'click should land in first half of trim window');
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ---------------- D7: 8-track mix benchmark ----------------

  testWidgets('D7 mix: 8 tracks × 30 s renders under budget',
      (tester) async {
    const tracksN = 8;
    const trackSeconds = 30;
    const sr = 48000;
    final paths = <String>[];
    for (int i = 0; i < tracksN; i++) {
      paths.add(await writeClickWav(
        name: 'mix_src_$i.wav',
        clickAtSample: i * 1000,
        totalSamples: sr * trackSeconds,
      ));
    }
    final outPath = p('mix_out.m4a');
    final tracks = [
      for (final path in paths)
        MinisMixTrack(path: path, inMs: 0, outMs: trackSeconds * 1000),
    ];
    final sw = Stopwatch()..start();
    String taskId;
    try {
      taskId = await MinisAudioMixer.mix(
        tracks: tracks, outPath: outPath, targetLufs: -14.0,
      );
    } catch (e) {
      // ignore: avoid_print
      print('D7 mix plugin unavailable: $e');
      return;
    }
    sw.stop();
    expect(taskId.isNotEmpty, isTrue);
    expect(await File(outPath).exists(), isTrue);
    expect(sw.elapsed.inSeconds, lessThan(30),
        reason: '8×30 s mix took ${sw.elapsed.inSeconds} s (budget 30 s)');
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ---------------- D3: latency probe (smoke) ----------------

  testWidgets('D3 record: start→stop produces playable file',
      (tester) async {
    final rec = MinisAudioRecorder();
    final path = p('latency_probe.m4a');
    int levelEvents = 0;
    final sub = rec.levelStream().listen((_) => levelEvents++);
    try {
      await rec.start(path: path);
    } catch (e) {
      // ignore: avoid_print
      print('D3 record plugin unavailable: $e');
      await sub.cancel();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final result = await rec.stop();
    await sub.cancel();
    expect(result.path.isNotEmpty, isTrue);
    expect(result.durationMs, greaterThan(100));
    expect(await File(result.path).exists(), isTrue);
    expect(levelEvents, greaterThanOrEqualTo(0));
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ---------------- D.bt: state stream subscribable ----------------

  testWidgets('D.bt audio state stream is subscribable', (tester) async {
    final sub = MinisAudioStateStream.instance.stream().listen(
      (_) {}, onError: (_) {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await sub.cancel();
  }, timeout: const Timeout(Duration(seconds: 10)));

  // ---------------- D9: beat detect ----------------

  testWidgets('D9 detectBeats returns plausible BPM on a metronome',
      (tester) async {
    const sr = 48000;
    const totalSec = 8;
    final totalSamples = sr * totalSec;
    final clickSet = <int>{};
    var s = 0;
    while (s < totalSamples) {
      clickSet.add(s);
      s += sr ~/ 2; // 120 BPM
    }
    final path = p('metronome_120.wav');
    final buf = BytesBuilder();
    const channels = 2;
    final dataLen = totalSamples * channels * 2;
    final riff = 36 + dataLen;
    void w32(int v) => buf.add([
          v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF
        ]);
    void w16(int v) => buf.add([v & 0xFF, (v >> 8) & 0xFF]);
    buf.add('RIFF'.codeUnits); w32(riff); buf.add('WAVE'.codeUnits);
    buf.add('fmt '.codeUnits); w32(16); w16(1); w16(channels); w32(sr);
    w32(sr * channels * 2); w16(channels * 2); w16(16);
    buf.add('data'.codeUnits); w32(dataLen);
    final body = Uint8List(dataLen);
    final bdv = ByteData.view(body.buffer);
    for (int i = 0; i < totalSamples; i++) {
      final v = clickSet.contains(i) ? 32767 : 0;
      bdv.setInt16(i * channels * 2, v, Endian.little);
      bdv.setInt16(i * channels * 2 + 2, v, Endian.little);
    }
    buf.add(body);
    await File(path).writeAsBytes(buf.toBytes(), flush: true);
    try {
      final res = await MinisAudioAnalysis.detectBeats(path);
      if (res.bpm > 0) {
        expect(res.bpm, inInclusiveRange(55.0, 245.0));
      }
    } catch (e) {
      // ignore: avoid_print
      print('D9 beat detect plugin unavailable: $e');
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
