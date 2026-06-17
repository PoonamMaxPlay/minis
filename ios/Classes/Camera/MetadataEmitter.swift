import AVFoundation
import Foundation

/// KVO bridge: observes exposureDuration / ISO / lensPosition /
/// deviceWhiteBalanceGains on an `AVCaptureDevice` and coalesces ticks at
/// `minIntervalMs` (default 33 ms / ~30 Hz).
public final class MinisMetadataEmitter: NSObject {
    public typealias Sink = (_ payload: [String: Any]) -> Void

    private weak var device: AVCaptureDevice?
    private let minIntervalMs: Double
    private var lastEmitMs: Double = 0
    private var sink: Sink?
    private var attached = false

    public init(device: AVCaptureDevice, minIntervalMs: Double = 33) {
        self.device = device
        self.minIntervalMs = minIntervalMs
        super.init()
    }

    public func attach(sink: @escaping Sink) {
        self.sink = sink
        guard let d = device, !attached else { return }
        d.addObserver(self, forKeyPath: "exposureDuration", options: [.new], context: nil)
        d.addObserver(self, forKeyPath: "ISO", options: [.new], context: nil)
        d.addObserver(self, forKeyPath: "lensPosition", options: [.new], context: nil)
        d.addObserver(self, forKeyPath: "deviceWhiteBalanceGains", options: [.new], context: nil)
        attached = true
    }

    public func detach() {
        guard let d = device, attached else { return }
        d.removeObserver(self, forKeyPath: "exposureDuration")
        d.removeObserver(self, forKeyPath: "ISO")
        d.removeObserver(self, forKeyPath: "lensPosition")
        d.removeObserver(self, forKeyPath: "deviceWhiteBalanceGains")
        attached = false
    }

    public override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        let now = Date().timeIntervalSince1970 * 1000.0
        if now - lastEmitMs < minIntervalMs { return }
        lastEmitMs = now
        guard let d = device else { return }
        let shutterSec = CMTimeGetSeconds(d.exposureDuration)
        let payload: [String: Any] = [
            "iso": Int(d.iso),
            "shutterNs": shutterSec.isFinite ? Int(shutterSec * 1_000_000_000) : NSNull(),
            "ev": Double(d.exposureTargetBias),
            "focus": Double(d.lensPosition),
            "wbKelvin": kelvinFromGains(d.deviceWhiteBalanceGains, on: d),
            "lensRatio": Double(d.videoZoomFactor),
            "frameTs": now,
        ]
        sink?(payload)
    }

    private func kelvinFromGains(_ g: AVCaptureDevice.WhiteBalanceGains, on device: AVCaptureDevice) -> Int {
        let tt = device.temperatureAndTintValues(for: g)
        let k = tt.temperature
        return k.isFinite ? Int(k) : 5500
    }

    deinit { detach() }
}
