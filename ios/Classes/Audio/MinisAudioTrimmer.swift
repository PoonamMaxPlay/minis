import AVFoundation
import Flutter
import Foundation

/// Container-boundary audio trim using AVAssetExportSession with the
/// AppleM4A preset. Cuts on AAC frame boundaries (1024 samples); sub-sample
/// accuracy requires a PCM round-trip and is deferred.
final class MinisAudioTrimmer {
    private let queue = DispatchQueue(label: "minis.audio.trim", qos: .utility)

    func trim(
        path: String,
        inMs: Int,
        outMs: Int,
        outPath: String,
        mode: String,
        result: @escaping FlutterResult
    ) {
        queue.async {
            if mode == "accurate" {
                self.runAccurate(path: path, inMs: inMs, outMs: outMs, outPath: outPath, result: result)
            } else {
                self.run(path: path, inMs: inMs, outMs: outMs, outPath: outPath, mode: mode, result: result)
            }
        }
    }

    private func runAccurate(
        path: String, inMs: Int, outMs: Int, outPath: String,
        result: @escaping FlutterResult
    ) {
        guard outMs > inMs else {
            DispatchQueue.main.async {
                result(FlutterError(code: "ARG", message: "outMs<=inMs", details: nil))
            }
            return
        }
        do {
            try? FileManager.default.removeItem(atPath: outPath)
            let dir = (outPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: nil
            )
            let pcm = try MinisPcmDecoder().decode(path: path)
            let sr = pcm.sampleRate
            let ch = pcm.channels
            let inSample = max(0, inMs * sr / 1000)
            let totalFrames = pcm.samples.count / ch
            let outSample = min(totalFrames, outMs * sr / 1000)
            guard outSample > inSample else {
                throw NSError(domain: "MinisAudioTrim", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "trim window outside source"])
            }
            let frames = outSample - inSample
            let slice = Array(pcm.samples[(inSample * ch)..<(inSample * ch + frames * ch)])
            try MinisAacEncoder().encode(samples: slice, sr: sr, ch: ch, outPath: outPath)
            DispatchQueue.main.async { result(["path": outPath]) }
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "MINIS_AUDIO_TRIM",
                    message: error.localizedDescription,
                    details: nil
                ))
            }
        }
    }

    private func run(
        path: String, inMs: Int, outMs: Int, outPath: String,
        mode: String, result: @escaping FlutterResult
    ) {
        guard outMs > inMs else {
            DispatchQueue.main.async {
                result(FlutterError(code: "ARG", message: "outMs<=inMs", details: nil))
            }
            return
        }
        try? FileManager.default.removeItem(atPath: outPath)
        let dir = (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else {
            DispatchQueue.main.async {
                result(FlutterError(
                    code: "MINIS_AUDIO_TRIM",
                    message: "AVAssetExportSession init failed",
                    details: nil
                ))
            }
            return
        }
        export.outputFileType = .m4a
        export.outputURL = URL(fileURLWithPath: outPath)
        let start = CMTime(value: CMTimeValue(inMs), timescale: 1000)
        let end = CMTime(value: CMTimeValue(outMs), timescale: 1000)
        export.timeRange = CMTimeRange(start: start, end: end)

        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously {
            sem.signal()
        }
        sem.wait()
        DispatchQueue.main.async {
            switch export.status {
            case .completed:
                result(["path": outPath])
            case .failed, .cancelled:
                result(FlutterError(
                    code: "MINIS_AUDIO_TRIM",
                    message: export.error?.localizedDescription ?? "trim failed",
                    details: nil
                ))
            default:
                result(FlutterError(
                    code: "MINIS_AUDIO_TRIM",
                    message: "unexpected export state",
                    details: nil
                ))
            }
        }
    }
}
