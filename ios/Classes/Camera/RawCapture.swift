import AVFoundation

/// RAW (DNG) photo capture support.
public enum MinisRawCapture {
    public static func isSupported(on photoOutput: AVCapturePhotoOutput) -> Bool {
        return !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
    }

    public static func rawSettings(on photoOutput: AVCapturePhotoOutput) -> AVCapturePhotoSettings? {
        guard let raw = photoOutput.availableRawPhotoPixelFormatTypes.first else { return nil }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
        settings.flashMode = .auto
        return settings
    }

    public static func jpegSettings(on photoOutput: AVCapturePhotoOutput, hdr: Bool) -> AVCapturePhotoSettings {
        let s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        s.flashMode = .auto
        if hdr {
            // HDR hint — `isAutoStillImageStabilizationEnabled` was removed in iOS 13;
            // we just request quality prioritization.
            if #available(iOS 13.0, *) { s.photoQualityPrioritization = .quality }
        }
        return s
    }
}
