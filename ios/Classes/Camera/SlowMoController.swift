import AVFoundation

/// High-speed video format negotiation (120 / 240 fps).
public enum MinisSlowMoController {
    public struct Result {
        public let enabled: Bool
        public let actualFps: Int
    }

    public static func supportedRates(on device: AVCaptureDevice) -> [Int] {
        var rates = Set<Int>()
        for f in device.formats {
            for r in f.videoSupportedFrameRateRanges {
                let upper = Int(r.maxFrameRate.rounded())
                if upper >= 60 { rates.insert(upper) }
            }
        }
        return rates.sorted()
    }

    public static func enable(on device: AVCaptureDevice, fps: Int) -> Result {
        let supported = supportedRates(on: device)
        let chosen = supported.last(where: { $0 <= fps }) ?? supported.last ?? 0
        guard chosen >= 60 else { return Result(enabled: false, actualFps: 0) }

        let format = device.formats.first { f in
            f.videoSupportedFrameRateRanges.contains { Int($0.maxFrameRate.rounded()) >= chosen }
        }
        guard let target = format else { return Result(enabled: false, actualFps: 0) }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = target
            let dur = CMTimeMake(value: 1, timescale: Int32(chosen))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            return Result(enabled: true, actualFps: chosen)
        } catch {
            return Result(enabled: false, actualFps: 0)
        }
    }
}
