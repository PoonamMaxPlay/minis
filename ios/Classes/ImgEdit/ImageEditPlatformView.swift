import Flutter
import Foundation
import UIKit

/// `loopit/minis/imgedit/canvas` PlatformView factory.
/// Each PlatformView creates an `ImageEditEngine` and registers it with
/// the shared `ImageEditPluginRouter` so MethodChannel calls reach it.
public final class ImageEditPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    public func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let params = (args as? [String: Any]) ?? [:]
        let sourcePath = params["sourcePath"] as? String
        let engine = ImageEditEngine(
            viewId: viewId,
            frame: frame,
            sourcePath: sourcePath
        )
        ImageEditPluginRouter.shared.register(engine)
        return ImageEditPlatformView(engine: engine)
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

private final class ImageEditPlatformView: NSObject, FlutterPlatformView {
    let engine: ImageEditEngine

    init(engine: ImageEditEngine) {
        self.engine = engine
        super.init()
    }

    func view() -> UIView {
        return engine.mtkView
    }
}
