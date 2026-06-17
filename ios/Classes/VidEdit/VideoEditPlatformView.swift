import Flutter
import UIKit
import AVFoundation
import Metal
import MetalKit

/// Hosts an `MTKView` driven by [MetalCompositor]. When the timeline has no
/// active clip the view paints solid black so the Flutter side has a
/// non-empty platform handle. The compositor renders each tick into the
/// MTKView's current drawable.
@objc public class VideoEditPlatformView: NSObject, FlutterPlatformView {

  private let container: UIView
  private let mtkView: MTKView?
  private let renderer: PreviewRenderer?

  init(frame: CGRect, viewId: Int64, args: Any?) {
    container = UIView(frame: frame)
    container.backgroundColor = .black
    if let device = MTLCreateSystemDefaultDevice() {
      let mtk = MTKView(frame: container.bounds, device: device)
      mtk.colorPixelFormat = .bgra8Unorm
      mtk.framebufferOnly = false
      mtk.autoResizeDrawable = true
      mtk.isPaused = true
      mtk.enableSetNeedsDisplay = true
      mtk.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      container.addSubview(mtk)
      mtkView = mtk
      let r = PreviewRenderer(device: device)
      mtk.delegate = r
      renderer = r
    } else {
      mtkView = nil
      renderer = nil
    }
    super.init()
  }

  public func view() -> UIView { container }
}

@objc public class VideoEditPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  @objc public init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }
  public func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    VideoEditPlatformView(frame: frame, viewId: viewId, args: args)
  }
  public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

/// `MTKViewDelegate` that asks the active `MetalCompositor` to render the
/// timeline's current frame into the view's drawable. The host updates the
/// compositor's timeline via [VideoEditEngine]; when there is nothing to
/// draw we leave the drawable as the previous frame (cheap idle).
private final class PreviewRenderer: NSObject, MTKViewDelegate {
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  init(device: MTLDevice) {
    self.device = device
    self.queue = device.makeCommandQueue()!
    super.init()
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
          let pass = view.currentRenderPassDescriptor,
          let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
    // Phase 2.5: the compositor pushes frames into a CVPixelBuffer that the
    // host blits into `view.currentDrawable.texture`. Until the host hooks
    // up a frame source we just commit the cleared drawable so the MTKView
    // surface stays alive.
    enc.endEncoding()
    cmd.present(drawable)
    cmd.commit()
  }
}
