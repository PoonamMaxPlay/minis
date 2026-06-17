import Flutter
import Foundation

final class Paths {
  static let channelName = "loopit/minis/paths"
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Paths.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  func dispose() { channel.setMethodCallHandler(nil) }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let fm = FileManager.default
    switch call.method {
    case "cacheDir":
      let url = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
      result(["path": url?.path as Any])
    case "appSupportDir":
      let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      if let u = url, !fm.fileExists(atPath: u.path) {
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
      }
      result(["path": url?.path as Any])
    case "documentsDir":
      let url = fm.urls(for: .documentDirectory, in: .userDomainMask).first
      result(["path": url?.path as Any])
    case "externalDir":
      result(["path": NSNull()])
    case "tempFile":
      let args = call.arguments as? [String: Any]
      var ext = (args?["ext"] as? String ?? "tmp").lowercased()
      if ext.hasPrefix(".") { ext.removeFirst() }
      let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
      let url = dir?.appendingPathComponent("\(UUID().uuidString).\(ext)")
      result(["path": url?.path as Any])
    case "join":
      let args = call.arguments as? [String: Any]
      let parts = (args?["parts"] as? [String]) ?? []
      var joined = ""
      for p in parts {
        if joined.isEmpty { joined = p; continue }
        if joined.hasSuffix("/") || p.hasPrefix("/") { joined += p } else { joined += "/" + p }
      }
      result(["path": joined])
    case "extension":
      let args = call.arguments as? [String: Any]
      let p = (args?["path"] as? String) ?? ""
      let ns = (p as NSString)
      let ext = ns.pathExtension
      result(["ext": ext.isEmpty ? "" : ".\(ext)"])
    case "basename":
      let args = call.arguments as? [String: Any]
      let p = (args?["path"] as? String) ?? ""
      result(["name": (p as NSString).lastPathComponent])
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
