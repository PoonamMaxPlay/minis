import AVFoundation
import Flutter
import Foundation

/// Offline pitch shift / time stretch via AVAudioEngine + AVAudioUnitTimePitch.
final class MinisPitchTimeStretch {
    private let queue = DispatchQueue(label: "minis.audio.pitch", qos: .utility)

    func timeStretch(
        path: String,
        factor: Double,
        keepPitch: Bool,
        outPath: String,
        result: @escaping FlutterResult
    ) {
        queue.async {
            do {
                let clamped = max(1.0 / 32.0, min(32.0, factor))
                let pitchCents: Float = keepPitch ? 0 : Float(-1200.0 * log2(clamped))
                try self.runEngine(
                    path: path,
                    outPath: outPath,
                    rate: Float(clamped),
                    pitchCents: pitchCents
                )
                DispatchQueue.main.async { result(["path": outPath]) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "MINIS_AUDIO_STRETCH",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    func pitchShift(
        path: String,
        semitones: Double,
        outPath: String,
        result: @escaping FlutterResult
    ) {
        queue.async {
            do {
                let cents = Float(semitones * 100.0)
                try self.runEngine(
                    path: path,
                    outPath: outPath,
                    rate: 1.0,
                    pitchCents: cents
                )
                DispatchQueue.main.async { result(["path": outPath]) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "MINIS_AUDIO_PITCH",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func runEngine(
        path: String,
        outPath: String,
        rate: Float,
        pitchCents: Float
    ) throws {
        let inURL = URL(fileURLWithPath: path)
        let outURL = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: outURL)
        let dir = (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )

        let inFile = try AVAudioFile(forReading: inURL)
        let processingFormat = inFile.processingFormat

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = max(1.0 / 32.0, min(32.0, rate))
        pitch.pitch = max(-2400.0, min(2400.0, pitchCents))

        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: processingFormat)

        // Output format for offline render.
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let maxFrames: AVAudioFrameCount = 4096

        if #available(iOS 11.0, *) {
            try engine.enableManualRenderingMode(
                .offline,
                format: outputFormat,
                maximumFrameCount: maxFrames
            )
        } else {
            throw NSError(
                domain: "MinisPitchTimeStretch", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "offline render requires iOS 11+"]
            )
        }

        try engine.start()
        player.scheduleFile(inFile, at: nil)
        player.play()

        // Output AAC m4a settings.
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputFormat.sampleRate,
            AVNumberOfChannelsKey: outputFormat.channelCount,
            AVEncoderBitRateKey: 128_000,
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: outSettings)

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: maxFrames
        ) else {
            engine.stop()
            engine.disableManualRenderingMode()
            throw NSError(
                domain: "MinisPitchTimeStretch", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "render buffer alloc failed"]
            )
        }

        // Expected output frames: ceil(inFile.length / rate).
        let sourceFrames = inFile.length
        let expectedFrames = AVAudioFramePosition(
            (Double(sourceFrames) / Double(pitch.rate)).rounded(.up)
        )

        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }

        while engine.manualRenderingSampleTime < expectedFrames {
            let remaining = expectedFrames - engine.manualRenderingSampleTime
            let frameCount = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), remaining))
            let status = try engine.renderOffline(frameCount, to: renderBuffer)
            switch status {
            case .success:
                if renderBuffer.frameLength > 0 {
                    try outFile.write(from: renderBuffer)
                }
            case .insufficientDataFromInputNode:
                // Player buffer drained.
                return
            case .cannotDoInCurrentContext:
                Thread.sleep(forTimeInterval: 0.005)
            case .error:
                throw NSError(
                    domain: "MinisPitchTimeStretch", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "renderOffline error"]
                )
            @unknown default:
                throw NSError(
                    domain: "MinisPitchTimeStretch", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "renderOffline unknown status"]
                )
            }
        }
    }
}
