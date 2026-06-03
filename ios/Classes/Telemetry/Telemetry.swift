import Flutter
import Foundation
import os.log

/// Native side of `loopit/minis/telemetry`.
///
/// Off by default. Hosts call `enable({sink: "log" | "stream"})` to turn it
/// on. Other engines in the plugin (camera, videdit, audio, etc.) call
/// `MinisTelemetry.publish(_:fields:)` to emit events; this object handles
/// routing.
///
/// Field scrubbing matches the Dart allow-list — only structural fields
/// pass through, never paths/URIs/raw bytes.
@objc public class MinisTelemetry: NSObject, FlutterStreamHandler {

  private enum SinkMode { case log, stream }

  // MARK: - Singleton wiring

  @objc public static let shared = MinisTelemetry()

  private var method: FlutterMethodChannel?
  private var events: FlutterEventChannel?
  private var sink: FlutterEventSink?

  private var enabled = false
  private var mode: SinkMode = .log
  private let log = OSLog(subsystem: "com.loopit.minis", category: "telemetry")
  private let queue = DispatchQueue(label: "loopit.minis.telemetry")

  @objc public func attach(messenger: FlutterBinaryMessenger) {
    let method = FlutterMethodChannel(
      name: "loopit/minis/telemetry",
      binaryMessenger: messenger
    )
    method.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }

    let events = FlutterEventChannel(
      name: "loopit/minis/telemetry/events",
      binaryMessenger: messenger
    )
    events.setStreamHandler(self)

    self.method = method
    self.events = events
  }

  @objc public func detach() {
    queue.sync {
      enabled = false
      sink = nil
    }
    method?.setMethodCallHandler(nil)
    events?.setStreamHandler(nil)
    method = nil
    events = nil
  }

  // MARK: - MethodChannel

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "enable":
      let args = call.arguments as? [String: Any]
      let sinkName = (args?["sink"] as? String) ?? "log"
      queue.sync {
        enabled = true
        mode = (sinkName == "stream") ? .stream : .log
      }
      result(nil)

    case "disable":
      queue.sync { enabled = false }
      result(nil)

    case "emit":
      let args = call.arguments as? [String: Any]
      let name = (args?["name"] as? String) ?? ""
      let fields = (args?["fields"] as? [String: Any]) ?? [:]
      MinisTelemetry.publish(name, fields: fields)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - StreamHandler

  public func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    queue.sync { sink = eventSink }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    queue.sync { sink = nil }
    return nil
  }

  // MARK: - Publish (called by engines)

  /// Engines inside the plugin call this to emit a telemetry event.
  @objc public static func publish(_ name: String, fields: [String: Any] = [:]) {
    shared.deliver(name: name, fields: scrub(fields))
  }

  private func deliver(name: String, fields: [String: Any]) {
    var enabledSnapshot = false
    var modeSnapshot: SinkMode = .log
    var sinkSnapshot: FlutterEventSink?

    queue.sync {
      enabledSnapshot = enabled
      modeSnapshot = mode
      sinkSnapshot = sink
    }

    guard enabledSnapshot else { return }

    switch modeSnapshot {
    case .log:
      os_log("%{public}@ %{public}@", log: log, type: .info, name, "\(fields)")
    case .stream:
      let payload: [String: Any] = [
        "name": name,
        "ts": Int(Date().timeIntervalSince1970 * 1000.0),
        "fields": fields,
      ]
      DispatchQueue.main.async {
        sinkSnapshot?(payload)
      }
    }
  }

  // MARK: - Scrub

  private static let allow: Set<String> = [
    "op", "kind", "durationMs", "pct", "fps", "codec", "profile",
    "width", "height", "sampleRate", "channels", "bitrateKbps",
    "thermal", "battery", "state", "result", "errorCode",
    "taskId", "segments", "count", "reason",
  ]

  private static func scrub(_ input: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in input {
      guard allow.contains(k) else { continue }
      if let s = v as? String, s.count > 64 { continue }
      out[k] = v
    }
    return out
  }
}
