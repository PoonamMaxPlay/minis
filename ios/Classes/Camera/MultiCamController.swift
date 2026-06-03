import AVFoundation
import UIKit

/// Front+back simultaneous capture via `AVCaptureMultiCamSession` (iOS 13+).
@available(iOS 13.0, *)
public final class MinisMultiCamController {
    public enum Layout: String { case topLeft, topRight, bottomLeft, bottomRight, sideBySide }

    public private(set) var session: AVCaptureMultiCamSession?
    public private(set) var backInput: AVCaptureDeviceInput?
    public private(set) var frontInput: AVCaptureDeviceInput?

    public init() {}

    public static var isSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    @discardableResult
    public func start() throws -> Bool {
        guard Self.isSupported else { return false }
        let s = AVCaptureMultiCamSession()
        s.beginConfiguration()
        defer { s.commitConfiguration() }
        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else { return false }
        let backIn = try AVCaptureDeviceInput(device: back)
        let frontIn = try AVCaptureDeviceInput(device: front)
        if s.canAddInput(backIn) { s.addInputWithNoConnections(backIn) }
        if s.canAddInput(frontIn) { s.addInputWithNoConnections(frontIn) }
        session = s
        backInput = backIn
        frontInput = frontIn
        return true
    }

    public func stop() {
        session?.stopRunning()
        session = nil
        backInput = nil
        frontInput = nil
    }
}
