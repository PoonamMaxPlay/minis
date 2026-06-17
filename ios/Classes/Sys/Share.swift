import Flutter
import UIKit

final class Share {
  static let channelName = "loopit/minis/share"
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Share.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  func dispose() { channel.setMethodCallHandler(nil) }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "share" else { result(FlutterMethodNotImplemented); return }
    let args = call.arguments as? [String: Any]
    let paths = (args?["paths"] as? [String]) ?? []
    let text = args?["text"] as? String
    let subject = args?["subject"] as? String
    var items: [Any] = paths.map { URL(fileURLWithPath: $0) }
    if let t = text, !t.isEmpty { items.append(t) }
    DispatchQueue.main.async {
      guard let root = UIApplication.shared.delegate?.window??.rootViewController else {
        result(FlutterError(code: "no_vc", message: "No view controller", details: nil)); return
      }
      let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
      if let s = subject { vc.setValue(s, forKey: "subject") }
      let presenter = root.presentedViewController ?? root
      if let pop = vc.popoverPresentationController {
        pop.sourceView = presenter.view
        pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        pop.permittedArrowDirections = []
      }
      presenter.present(vc, animated: true) { result(nil) }
    }
  }
}
