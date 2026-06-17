import AVFoundation
import Flutter

/// Native permissions channel `loopit/minis/permissions`.
public final class MinisCameraPermissions {
    public init() {}

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "status":
            result([
                "camera": (AVCaptureDevice.authorizationStatus(for: .video) == .authorized),
                "microphone": (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized),
            ])
        case "requestCamera":
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { result(ok) }
            }
        case "requestMicrophone":
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { result(ok) }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
