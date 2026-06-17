import AVFoundation
import Flutter
import Foundation

/// AVAudioRecorder for AAC/WAV. Opus path goes through MinisOpusEncoder
/// (iOS 13+, raw bitstream — not Ogg-muxed). MP3 still needs vendored LAME.
/// `denoise`/`monitor` flags route through MinisVoiceIO (VoiceProcessingIO
/// session mode, which engages OS-level AEC + NS + AGC).
final class MinisRecorder {
    private var recorder: AVAudioRecorder?
    private var outputPath: String = ""
    private var activeFormat: String = "aac"
    private var startedAt: Date = Date()
    private var accumulated: TimeInterval = 0
    private let levelMeter = MinisLevelMeter()
    private let voiceIO = MinisVoiceIO()
    private let lame = MinisLameEncoder()
    private var pcmCapturePath: String = ""
    private var pcmSampleRate: Int = 44100
    private var pcmChannels: Int = 1
    private var voiceEnabled: Bool = false

    func attachLevelSink(_ sink: FlutterEventSink?) {
        levelMeter.attachSink(sink)
    }

    func start(
        path: String,
        format: String,
        sampleRate: Int,
        channels: Int,
        bitRate: Int,
        denoise: Bool = false,
        monitor: Bool = false
    ) throws {
        stopInternal()
        outputPath = path
        activeFormat = format
        pcmSampleRate = sampleRate
        pcmChannels = channels

        if format == "mp3" {
            if !MinisLameEncoder.isAvailable() {
                throw NSError(
                    domain: "MinisRecorder", code: -10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "format=mp3 needs LAME — run ios/scripts/fetch_lame.sh and link Vendor/lame/libmp3lame.a"]
                )
            }
            pcmCapturePath = path + ".pcm"
            try startWavCapture(path: pcmCapturePath, sampleRate: sampleRate, channels: channels)
            return
        }

        if denoise || monitor {
            do {
                try voiceIO.enableForMonitoring()
                voiceEnabled = true
            } catch {
                voiceEnabled = false
            }
        }

        // Opus path: capture WAV PCM, encode on stop.
        if format == "opus" {
            if !MinisOpusEncoder.isAvailable() {
                throw NSError(
                    domain: "MinisRecorder", code: -11,
                    userInfo: [NSLocalizedDescriptionKey:
                        "format=opus requires iOS 13+ (AVAudioConverter Opus)"]
                )
            }
            pcmCapturePath = path + ".pcm"
            try startWavCapture(path: pcmCapturePath, sampleRate: sampleRate, channels: channels)
            return
        }

        let url = URL(fileURLWithPath: path)
        var settings: [String: Any]
        switch format {
        case "wav":
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
            ]
        default:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitRate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        }
        try startAvRecorder(url: url, settings: settings)
    }

    private func startWavCapture(path: String, sampleRate: Int, channels: Int) throws {
        let url = URL(fileURLWithPath: path)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        try startAvRecorder(url: url, settings: settings)
    }

    private func startAvRecorder(url: URL, settings: [String: Any]) throws {
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.prepareToRecord() else {
            throw NSError(domain: "MinisRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "prepareToRecord failed"])
        }
        guard r.record() else {
            throw NSError(domain: "MinisRecorder", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "record() returned false"])
        }
        recorder = r
        startedAt = Date()
        accumulated = 0
        levelMeter.start(r)
    }

    func pause() {
        guard let r = recorder, r.isRecording else { return }
        r.pause()
        accumulated += Date().timeIntervalSince(startedAt)
    }

    func resume() {
        guard let r = recorder else { return }
        r.record()
        startedAt = Date()
    }

    func stop() -> [String: Any] {
        guard let r = recorder else { return ["path": outputPath, "durationMs": 0] }
        let total = accumulated + Date().timeIntervalSince(startedAt)
        levelMeter.stop()
        r.stop()
        recorder = nil
        if voiceEnabled {
            try? voiceIO.disable()
            voiceEnabled = false
        }
        if activeFormat == "opus" {
            do {
                let dec = try MinisPcmDecoder().decode(path: pcmCapturePath)
                try MinisOpusEncoder().encode(
                    samples: dec.samples,
                    sr: dec.sampleRate,
                    ch: dec.channels,
                    outPath: outputPath
                )
                try? FileManager.default.removeItem(atPath: pcmCapturePath)
            } catch {
                return [
                    "path": "",
                    "durationMs": 0,
                    "error": "opus encode failed: \(error.localizedDescription)",
                ]
            }
        }
        if activeFormat == "mp3" {
            do {
                let dec = try MinisPcmDecoder().decode(path: pcmCapturePath)
                try lame.encode(
                    samples: dec.samples,
                    sr: dec.sampleRate,
                    ch: dec.channels,
                    outPath: outputPath
                )
                try? FileManager.default.removeItem(atPath: pcmCapturePath)
            } catch {
                return [
                    "path": "",
                    "durationMs": 0,
                    "error": "mp3 encode failed: \(error.localizedDescription)",
                ]
            }
        }
        return ["path": outputPath, "durationMs": Int(total * 1000.0)]
    }

    private func stopInternal() {
        levelMeter.stop()
        recorder?.stop()
        recorder = nil
        if voiceEnabled {
            try? voiceIO.disable()
            voiceEnabled = false
        }
    }
}
