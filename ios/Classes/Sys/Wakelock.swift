import Flutter
import UIKit

final class Wakelock {
  static let channelName = "loopit/minis/wakelock"
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Wakelock.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      DispatchQueue.main.async {
        switch call.method {
        case "enable":
          UIApplication.shared.isIdleTimerDisabled = true
          result(nil)
        case "disable":
          UIApplication.shared.isIdleTimerDisabled = false
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  func dispose() {
    UIApplication.shared.isIdleTimerDisabled = false
    channel.setMethodCallHandler(nil)
  }
}
