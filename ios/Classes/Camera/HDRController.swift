import AVFoundation

/// HDR (HEVC HDR10 / Dolby Vision IQ) format selection on a device.
public enum MinisHDRController {

    public static func isSupported(on device: AVCaptureDevice) -> Bool {
        return device.formats.contains { $0.isVideoHDRSupported }
    }

    /// Pick the highest-resolution format that flags `isVideoHDRSupported` and
    /// switch the device to it. Returns whether a switch happened.
    @discardableResult
    public static func enable(on device: AVCaptureDevice) -> Bool {
        let hdrFormats = device.formats.filter { $0.isVideoHDRSupported }
        guard let best = hdrFormats.max(by: { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return (Int(l.width) * Int(l.height)) < (Int(r.width) * Int(r.height))
        }) else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = best
            if #available(iOS 14.5, *) {
                if best.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = true
                }
            }
            return true
        } catch {
            return false
        }
    }

    public static func disable(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if #available(iOS 14.5, *) {
                device.automaticallyAdjustsVideoHDREnabled = true
            }
        } catch { /* ignore */ }
    }
}
