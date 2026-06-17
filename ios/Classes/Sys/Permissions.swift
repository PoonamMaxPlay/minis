import Flutter
import AVFoundation
import Photos
import CoreLocation
import UserNotifications
import UIKit

final class Permissions: NSObject {
  static let methodChannelName = "loopit/minis/permissions"
  static let eventChannelName = "loopit/minis/permissions/events"

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var locationManager: CLLocationManager?
  private var pendingLocationResult: ((String) -> Void)?
  private var wantsLocationAlways = false

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: Permissions.methodChannelName, binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(name: Permissions.eventChannelName, binaryMessenger: messenger)
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
    eventChannel.setStreamHandler(Streamer(onListen: { [weak self] sink in self?.eventSink = sink }, onCancel: { [weak self] in self?.eventSink = nil }))
    NotificationCenter.default.addObserver(self, selector: #selector(onForeground), name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  func dispose() {
    methodChannel.setMethodCallHandler(nil)
    eventChannel.setStreamHandler(nil)
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func onForeground() {
    eventSink?(["kind": "settingsReturned"])
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "check":
      guard let key = args?["permission"] as? String else { result(FlutterError(code: "arg", message: "permission required", details: nil)); return }
      result(["status": status(for: key)])
    case "request":
      guard let key = args?["permission"] as? String else { result(FlutterError(code: "arg", message: "permission required", details: nil)); return }
      request(key) { s in result(["status": s]) }
    case "requestMulti":
      let keys = (args?["permissions"] as? [String]) ?? []
      requestMulti(keys) { map in result(["map": map]) }
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func status(for key: String) -> String {
    switch key {
    case "camera": return mapAV(AVCaptureDevice.authorizationStatus(for: .video))
    case "microphone": return mapAV(AVCaptureDevice.authorizationStatus(for: .audio))
    case "photos":
      if #available(iOS 14, *) { return mapPH(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }
      return mapPH(PHPhotoLibrary.authorizationStatus())
    case "photosAdd":
      if #available(iOS 14, *) { return mapPH(PHPhotoLibrary.authorizationStatus(for: .addOnly)) }
      return mapPH(PHPhotoLibrary.authorizationStatus())
    case "location":
      return mapCL(CLLocationManager.authorizationStatus(), always: false)
    case "locationAlways":
      return mapCL(CLLocationManager.authorizationStatus(), always: true)
    case "notification":
      var s = "denied"
      let sem = DispatchSemaphore(value: 0)
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: s = "granted"
        case .denied: s = "permDenied"
        case .notDetermined: s = "denied"
        @unknown default: s = "denied"
        }
        sem.signal()
      }
      _ = sem.wait(timeout: .now() + 0.5)
      return s
    case "storage": return "granted"
    default: return "denied"
    }
  }

  private func request(_ key: String, completion: @escaping (String) -> Void) {
    switch key {
    case "camera":
      AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { completion(ok ? "granted" : "permDenied") } }
    case "microphone":
      AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { completion(ok ? "granted" : "permDenied") } }
    case "photos":
      if #available(iOS 14, *) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in DispatchQueue.main.async { completion(self.mapPH(s)) } }
      } else {
        PHPhotoLibrary.requestAuthorization { s in DispatchQueue.main.async { completion(self.mapPH(s)) } }
      }
    case "photosAdd":
      if #available(iOS 14, *) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in DispatchQueue.main.async { completion(self.mapPH(s)) } }
      } else {
        PHPhotoLibrary.requestAuthorization { s in DispatchQueue.main.async { completion(self.mapPH(s)) } }
      }
    case "location", "locationAlways":
      let always = key == "locationAlways"
      wantsLocationAlways = always
      pendingLocationResult = completion
      if locationManager == nil {
        locationManager = CLLocationManager()
        locationManager?.delegate = self
      }
      if always { locationManager?.requestAlwaysAuthorization() }
      else { locationManager?.requestWhenInUseAuthorization() }
    case "notification":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
        DispatchQueue.main.async { completion(ok ? "granted" : "permDenied") }
      }
    case "storage":
      completion("granted")
    default:
      completion("denied")
    }
  }

  private func requestMulti(_ keys: [String], completion: @escaping ([String: String]) -> Void) {
    var result: [String: String] = [:]
    let group = DispatchGroup()
    for k in keys {
      group.enter()
      request(k) { s in result[k] = s; group.leave() }
    }
    group.notify(queue: .main) { completion(result) }
  }

  private func mapAV(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "granted"
    case .denied: return "permDenied"
    case .restricted: return "restricted"
    case .notDetermined: return "denied"
    @unknown default: return "denied"
    }
  }
  private func mapPH(_ s: PHAuthorizationStatus) -> String {
    switch s {
    case .authorized, .limited: return "granted"
    case .denied: return "permDenied"
    case .restricted: return "restricted"
    case .notDetermined: return "denied"
    @unknown default: return "denied"
    }
  }
  private func mapCL(_ s: CLAuthorizationStatus, always: Bool) -> String {
    switch s {
    case .authorizedAlways: return "granted"
    case .authorizedWhenInUse: return always ? "denied" : "granted"
    case .denied: return "permDenied"
    case .restricted: return "restricted"
    case .notDetermined: return "denied"
    @unknown default: return "denied"
    }
  }

  private final class Streamer: NSObject, FlutterStreamHandler {
    let onListen: (FlutterEventSink) -> Void
    let onCancelCb: () -> Void
    init(onListen: @escaping (FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
      self.onListen = onListen; self.onCancelCb = onCancel
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
      onListen(events); return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { onCancelCb(); return nil }
  }
}

extension Permissions: CLLocationManagerDelegate {
  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    guard status != .notDetermined, let cb = pendingLocationResult else { return }
    pendingLocationResult = nil
    DispatchQueue.main.async { cb(self.mapCL(status, always: self.wantsLocationAlways)) }
  }
  @available(iOS 14, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let s = manager.authorizationStatus
    guard s != .notDetermined, let cb = pendingLocationResult else { return }
    pendingLocationResult = nil
    DispatchQueue.main.async { cb(self.mapCL(s, always: self.wantsLocationAlways)) }
  }
}
