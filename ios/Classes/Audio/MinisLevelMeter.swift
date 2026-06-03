import AVFoundation
import Flutter
import Foundation

/// Polls an `AVAudioRecorder` for peak/average power at ~60 Hz and pushes
/// {peakDb, rmsDb, ts} to the Flutter levels EventChannel sink.
///
/// TODO(improvement4.md D3): once the AVAudioEngine input-node tap path lands
/// (D1.x sibling on iOS), replace the polling approach with the tap buffer.
final class MinisLevelMeter {
    private var recorder: AVAudioRecorder?
    private var sink: FlutterEventSink?
    private var timer: DispatchSourceTimer?
    private var lastPostMs: Int64 = 0
    private let queue = DispatchQueue(label: "minis.audio.levels", qos: .userInteractive)

    func attachSink(_ s: FlutterEventSink?) {
        sink = s
    }

    func start(_ r: AVAudioRecorder) {
        stop()
        recorder = r
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        recorder = nil
    }

    private func tick() {
        guard let r = recorder, r.isRecording, let s = sink else { return }
        r.updateMeters()
        let peak = Double(r.peakPower(forChannel: 0))
        let rms = Double(r.averagePower(forChannel: 0))
        let now = Int64(Date().timeIntervalSince1970 * 1000.0)
        if now - lastPostMs < 16 { return }
        lastPostMs = now
        let peakDb = max(-80.0, peak.isFinite ? peak : -80.0)
        let rmsDb = max(-80.0, rms.isFinite ? rms : -80.0)
        DispatchQueue.main.async {
            s([
                "peakDb": peakDb,
                "rmsDb": rmsDb,
                "ts": now,
            ])
        }
    }
}
