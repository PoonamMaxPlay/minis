import Flutter
import UIKit
import AVFoundation

final class VideoPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "loopit/minis/player"
  private let engine: VideoPlayerEngine
  init(engine: VideoPlayerEngine) { self.engine = engine }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let params = args as? [String: Any]
    let playerId = (params?["playerId"] as? String) ?? ""
    let fit = (params?["fit"] as? String) ?? "contain"
    let hdrTonemap = (params?["hdrTonemap"] as? Bool) ?? true
    return VideoPlayerView(frame: frame, playerId: playerId, fit: fit, hdrTonemap: hdrTonemap, engine: engine)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
}

final class VideoPlayerView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let playerLayer: AVPlayerLayer
  private let playerId: String
  private weak var engine: VideoPlayerEngine?

  init(frame: CGRect, playerId: String, fit: String, hdrTonemap: Bool, engine: VideoPlayerEngine) {
    self.container = HostView(frame: frame)
    self.playerLayer = AVPlayerLayer()
    self.playerId = playerId
    self.engine = engine
    super.init()
    playerLayer.videoGravity = (fit == "cover") ? .resizeAspectFill : .resizeAspect
    playerLayer.frame = container.bounds
    if hdrTonemap, #available(iOS 14, *) {
      // Hint AVPlayerLayer's display pipeline to tone-map HDR to BT.709 (SDR)
      // on SDR displays. Honored when the source carries HDR transfer metadata.
      playerLayer.pixelBufferAttributes = [
        String(kCVPixelBufferTransferFunctionKey): kCVImageBufferTransferFunction_ITU_R_709_2
      ]
    }
    container.layer.addSublayer(playerLayer)
    (container as? HostView)?.onLayout = { [weak self] in self?.playerLayer.frame = self?.container.bounds ?? .zero }
    engine.attach(layer: playerLayer, to: playerId)
  }

  func view() -> UIView { container }

  deinit { engine?.detach(playerId: playerId) }
}

private final class HostView: UIView {
  var onLayout: (() -> Void)?
  override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
}
