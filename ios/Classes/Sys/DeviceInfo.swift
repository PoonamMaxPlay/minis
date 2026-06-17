import Flutter
import UIKit
import AVFoundation
import Metal

final class DeviceInfo: NSObject {
  static let methodChannelName = "loopit/minis/device"
  static let thermalChannelName = "loopit/minis/device/thermal"

  private let methodChannel: FlutterMethodChannel
  private let thermalChannel: FlutterEventChannel
  private var thermalSink: FlutterEventSink?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: DeviceInfo.methodChannelName, binaryMessenger: messenger)
    thermalChannel = FlutterEventChannel(name: DeviceInfo.thermalChannelName, binaryMessenger: messenger)
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    thermalChannel.setStreamHandler(Streamer(onListen: { [weak self] sink in
      self?.thermalSink = sink
      NotificationCenter.default.addObserver(self as Any, selector: #selector(self?.onThermalChange), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }, onCancel: { [weak self] in
      NotificationCenter.default.removeObserver(self as Any, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
      self?.thermalSink = nil
    }))
    UIDevice.current.isBatteryMonitoringEnabled = true
  }

  func dispose() {
    methodChannel.setMethodCallHandler(nil)
    thermalChannel.setStreamHandler(nil)
  }

  @objc private func onThermalChange() {
    thermalSink?(["state": thermalString(ProcessInfo.processInfo.thermalState)])
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "info":
      result(buildInfo())
    case "thermal":
      result(["state": thermalString(ProcessInfo.processInfo.thermalState)])
    case "battery":
      let level = UIDevice.current.batteryLevel
      let percent = level >= 0 ? Int(level * 100) : -1
      let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
      result(["percent": percent, "charging": charging])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func buildInfo() -> [String: Any?] {
    let dev = UIDevice.current
    let physMem = ProcessInfo.processInfo.physicalMemory
    let ramMb = Int(physMem / (1024 * 1024))
    let gpu = MTLCreateSystemDefaultDevice()?.name ?? "metal"
    var codecs: [String] = []
    if #available(iOS 11, *) {
      codecs = ["h264", "hevc"]
    }
    var hdr: [String: Any] = ["hdr10": false, "dolbyVision": false]
    if #available(iOS 11, *) {
      let formats = AVPlayer.availableHDRModes
      hdr["hdr10"] = formats.contains(.hdr10)
      hdr["dolbyVision"] = formats.contains(.dolbyVision)
    }
    var sys = utsname()
    uname(&sys)
    let machine = withUnsafePointer(to: &sys.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    let isPhysical: Bool
    #if targetEnvironment(simulator)
      isPhysical = false
    #else
      isPhysical = true
    #endif
    return [
      "model": dev.model,
      "os": "ios",
      "osVersion": dev.systemVersion,
      "ramMb": ramMb,
      "gpu": gpu,
      "codecs": codecs,
      "hdrCapabilities": hdr,
      "machine": machine,
      "isPhysicalDevice": isPhysical
    ]
  }

  private func thermalString(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "light"
    case .serious: return "severe"
    case .critical: return "critical"
    @unknown default: return "nominal"
    }
  }

  private final class Streamer: NSObject, FlutterStreamHandler {
    let onListenCb: (FlutterEventSink) -> Void
    let onCancelCb: () -> Void
    init(onListen: @escaping (FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
      self.onListenCb = onListen; self.onCancelCb = onCancel
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { onListenCb(events); return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { onCancelCb(); return nil }
  }
}
