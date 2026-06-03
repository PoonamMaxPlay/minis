import AVFoundation
import Flutter
import UIKit

/// PlatformView host. `secondary == true` is the multi-cam PiP view.
public final class MinisCameraPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    public let engine: MinisCameraEngine
    public let secondary: Bool
    public init(engine: MinisCameraEngine, secondary: Bool = false) {
        self.engine = engine
        self.secondary = secondary
    }

    public func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        let v = MinisCameraPlatformView(frame: frame)
        if secondary { engine.secondaryPreview = v } else { engine.primaryPreview = v }
        v.attach(session: engine.session)
        return v
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

public final class MinisCameraPlatformView: NSObject, FlutterPlatformView {
    public let container = UIView()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    public init(frame: CGRect) {
        super.init()
        container.frame = frame
        container.backgroundColor = .black
        container.clipsToBounds = true
    }

    public func attach(session: AVCaptureSession) {
        previewLayer?.removeFromSuperlayer()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = container.bounds
        container.layer.addSublayer(layer)
        previewLayer = layer
    }

    public func view() -> UIView { return container }
}
