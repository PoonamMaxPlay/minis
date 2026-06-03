import AVFoundation
import CoreGraphics

/// Manual ISO / shutter / WB / focus / EV on an `AVCaptureDevice`.
public enum MinisManualControls {

    public struct Ranges {
        public let minIso: Float?
        public let maxIso: Float?
        public let minShutterSeconds: Double?
        public let maxShutterSeconds: Double?
        public let minEv: Float?
        public let maxEv: Float?
    }

    public static func ranges(of device: AVCaptureDevice) -> Ranges {
        let fmt = device.activeFormat
        return Ranges(
            minIso: fmt.minISO,
            maxIso: fmt.maxISO,
            minShutterSeconds: CMTimeGetSeconds(fmt.minExposureDuration),
            maxShutterSeconds: CMTimeGetSeconds(fmt.maxExposureDuration),
            minEv: device.minExposureTargetBias,
            maxEv: device.maxExposureTargetBias
        )
    }

    public static func setManual(
        device: AVCaptureDevice,
        iso: Float?,
        shutterNs: Int64?,
        wbKelvin: Int?,
        lensPosition: Float?
    ) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if iso != nil || shutterNs != nil {
            let isoVal = iso ?? device.iso
            let shutterCm: CMTime
            if let ns = shutterNs {
                shutterCm = CMTimeMake(value: ns, timescale: 1_000_000_000)
            } else {
                shutterCm = AVCaptureDevice.currentExposureDuration
            }
            device.setExposureModeCustom(
                duration: shutterCm,
                iso: clamp(isoVal, low: device.activeFormat.minISO, high: device.activeFormat.maxISO),
                completionHandler: nil
            )
        }

        if let kelvin = wbKelvin {
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: Float(kelvin),
                tint: 0
            )
            let gains = device.deviceWhiteBalanceGains(for: tt)
            let safe = clampGains(gains, max: device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with: safe, completionHandler: nil)
        }

        if let pos = lensPosition {
            device.setFocusModeLocked(lensPosition: clamp(pos, low: 0, high: 1), completionHandler: nil)
        }
    }

    public static func setExposureBias(device: AVCaptureDevice, ev: Float) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let clamped = clamp(ev, low: device.minExposureTargetBias, high: device.maxExposureTargetBias)
        device.setExposureTargetBias(clamped, completionHandler: nil)
    }

    public static func setFocusPoint(device: AVCaptureDevice, point: CGPoint) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
        }
        if device.isFocusModeSupported(.autoFocus) {
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
        }
        if device.isExposureModeSupported(.autoExpose) {
            device.exposureMode = .autoExpose
        }
    }

    public static func setTorch(device: AVCaptureDevice, on: Bool, level: Float = 1.0) throws {
        guard device.hasTorch else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if on {
            if device.isTorchModeSupported(.on) {
                try device.setTorchModeOn(level: min(max(level, 0.01), AVCaptureDevice.maxAvailableTorchLevel))
            }
        } else {
            device.torchMode = .off
        }
    }

    private static func clamp<T: Comparable>(_ v: T, low: T, high: T) -> T {
        return min(max(v, low), high)
    }

    private static func clampGains(_ g: AVCaptureDevice.WhiteBalanceGains, max: Float) -> AVCaptureDevice.WhiteBalanceGains {
        var out = g
        out.redGain = min(out.redGain, max)
        out.greenGain = min(out.greenGain, max)
        out.blueGain = min(out.blueGain, max)
        out.redGain = Swift.max(out.redGain, 1)
        out.greenGain = Swift.max(out.greenGain, 1)
        out.blueGain = Swift.max(out.blueGain, 1)
        return out
    }
}
