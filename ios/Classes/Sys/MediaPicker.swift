import Flutter
import UIKit
import PhotosUI
import AVFoundation
import MobileCoreServices
import Photos

@available(iOS 14, *)
final class MediaPicker: NSObject {
  static let channelName = "loopit/minis/picker"
  private let channel: FlutterMethodChannel
  private let filePicker: FilePickerNative

  init(messenger: FlutterBinaryMessenger, filePicker: FilePickerNative) {
    channel = FlutterMethodChannel(name: MediaPicker.channelName, binaryMessenger: messenger)
    self.filePicker = filePicker
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  func dispose() { channel.setMethodCallHandler(nil) }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = (call.arguments as? [String: Any]) ?? [:]
    switch call.method {
    case "pickImage": pickImage(args, result: result)
    case "pickVideo": pickVideo(args, result: result)
    case "pickMedia": pickMedia(args, result: result)
    case "pickFile": filePicker.pickFile(args, result: result)
    case "saveToGallery": saveToGallery(args, result: result)
    case "share": result(FlutterMethodNotImplemented)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func pickImage(_ args: [String: Any], result: @escaping FlutterResult) {
    let source = (args["source"] as? String) ?? "gallery"
    if source == "camera" { presentCamera(forVideo: false, args: args, result: result) }
    else { presentPhPicker(filter: .images, multi: false, result: result) }
  }
  private func pickVideo(_ args: [String: Any], result: @escaping FlutterResult) {
    let source = (args["source"] as? String) ?? "gallery"
    if source == "camera" { presentCamera(forVideo: true, args: args, result: result) }
    else { presentPhPicker(filter: .videos, multi: false, result: result) }
  }
  private func pickMedia(_ args: [String: Any], result: @escaping FlutterResult) {
    let multi = (args["multi"] as? Bool) ?? false
    let types = (args["types"] as? [String]) ?? ["image", "video"]
    let img = types.contains("image"), vid = types.contains("video")
    let filter: PHPickerFilter
    if img && vid { filter = .any(of: [.images, .videos]) }
    else if img { filter = .images }
    else { filter = .videos }
    presentPhPicker(filter: filter, multi: multi, result: result)
  }

  private func presentPhPicker(filter: PHPickerFilter, multi: Bool, result: @escaping FlutterResult) {
    var cfg = PHPickerConfiguration()
    cfg.filter = filter
    cfg.selectionLimit = multi ? 0 : 1
    let picker = PHPickerViewController(configuration: cfg)
    let delegate = PhPickerDelegate(multi: multi) { [weak self] items in
      result(self?.bundleItems(items, multi: multi) ?? (multi ? ["items": []] : NSNull()))
    }
    picker.delegate = delegate
    objc_setAssociatedObject(picker, &PhPickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    presentTop(picker)
  }

  private func bundleItems(_ items: [[String: Any?]], multi: Bool) -> Any {
    if multi { return ["items": items] }
    return items.first ?? NSNull()
  }

  private func presentCamera(forVideo: Bool, args: [String: Any], result: @escaping FlutterResult) {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      result(FlutterError(code: "no_camera", message: "Camera not available", details: nil)); return
    }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = forVideo ? [kUTTypeMovie as String] : [kUTTypeImage as String]
    if forVideo, let maxMs = args["maxDurationMs"] as? Int { picker.videoMaximumDuration = TimeInterval(maxMs) / 1000.0 }
    let delegate = CameraDelegate(forVideo: forVideo) { item in result(item ?? NSNull()) }
    picker.delegate = delegate
    objc_setAssociatedObject(picker, &CameraDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    presentTop(picker)
  }

  private func saveToGallery(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String else { result(FlutterError(code: "arg", message: "path required", details: nil)); return }
    let url = URL(fileURLWithPath: path)
    let isVideo = ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    PHPhotoLibrary.shared().performChanges({
      if isVideo {
        PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
      } else {
        PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
      }
    }, completionHandler: { ok, err in
      DispatchQueue.main.async {
        if ok { result(["uri": url.absoluteString]) }
        else { result(FlutterError(code: "save_fail", message: err?.localizedDescription, details: nil)) }
      }
    })
  }

  private func presentTop(_ vc: UIViewController) {
    DispatchQueue.main.async {
      guard let root = UIApplication.shared.delegate?.window??.rootViewController else { return }
      (root.presentedViewController ?? root).present(vc, animated: true)
    }
  }
}

@available(iOS 14, *)
final class PhPickerDelegate: NSObject, PHPickerViewControllerDelegate {
  static var key: UInt8 = 0
  let multi: Bool
  let completion: ([[String: Any?]]) -> Void
  init(multi: Bool, completion: @escaping ([[String: Any?]]) -> Void) {
    self.multi = multi; self.completion = completion
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    if results.isEmpty { completion([]); return }
    var items: [[String: Any?]] = []
    let group = DispatchGroup()
    let tmp = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    for r in results {
      group.enter()
      let provider = r.itemProvider
      let typeId: String
      if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { typeId = UTType.movie.identifier }
      else { typeId = UTType.image.identifier }
      provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
        defer { group.leave() }
        guard let url = url else { return }
        let dest = tmp.appendingPathComponent("pick_\(UUID().uuidString).\(url.pathExtension)")
        try? FileManager.default.copyItem(at: url, to: dest)
        items.append(self.describe(url: dest, typeId: typeId))
      }
    }
    group.notify(queue: .main) { self.completion(items) }
  }
  private func describe(url: URL, typeId: String) -> [String: Any?] {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    var w = 0, h = 0, durMs = 0
    if typeId == UTType.movie.identifier {
      let asset = AVURLAsset(url: url)
      if let track = asset.tracks(withMediaType: .video).first {
        let sz = track.naturalSize.applying(track.preferredTransform)
        w = Int(abs(sz.width)); h = Int(abs(sz.height))
      }
      durMs = Int(CMTimeGetSeconds(asset.duration) * 1000)
    } else if let img = UIImage(contentsOfFile: url.path) {
      w = Int(img.size.width); h = Int(img.size.height)
    }
    let mime = (typeId == UTType.movie.identifier) ? "video/quicktime" : "image/jpeg"
    return ["path": url.path, "mime": mime, "size": size, "w": w, "h": h, "durationMs": durMs]
  }
}

final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  static var key: UInt8 = 0
  let forVideo: Bool
  let completion: ([String: Any?]?) -> Void
  init(forVideo: Bool, completion: @escaping ([String: Any?]?) -> Void) {
    self.forVideo = forVideo; self.completion = completion
  }
  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    picker.dismiss(animated: true)
    let tmp = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    if forVideo {
      guard let url = info[.mediaURL] as? URL else { completion(nil); return }
      let dest = tmp.appendingPathComponent("cap_\(UUID().uuidString).\(url.pathExtension)")
      try? FileManager.default.copyItem(at: url, to: dest)
      let asset = AVURLAsset(url: dest)
      let durMs = Int(CMTimeGetSeconds(asset.duration) * 1000)
      var w = 0, h = 0
      if let track = asset.tracks(withMediaType: .video).first {
        let sz = track.naturalSize.applying(track.preferredTransform)
        w = Int(abs(sz.width)); h = Int(abs(sz.height))
      }
      completion(["path": dest.path, "mime": "video/quicktime", "size": (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int ?? 0, "w": w, "h": h, "durationMs": durMs])
    } else {
      guard let img = info[.originalImage] as? UIImage, let data = img.jpegData(compressionQuality: 0.92) else { completion(nil); return }
      let dest = tmp.appendingPathComponent("cap_\(UUID().uuidString).jpg")
      try? data.write(to: dest)
      completion(["path": dest.path, "mime": "image/jpeg", "size": data.count, "w": Int(img.size.width), "h": Int(img.size.height), "durationMs": 0])
    }
  }
  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true); completion(nil)
  }
}
