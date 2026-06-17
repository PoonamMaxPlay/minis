import Flutter
import UIKit
import UniformTypeIdentifiers

final class FilePickerNative: NSObject {
  private var pendingResult: FlutterResult?
  private var pendingMulti = false
  private var allowedExts: [String] = []

  func pickFile(_ args: [String: Any], result: @escaping FlutterResult) {
    let multi = (args["multi"] as? Bool) ?? false
    let mimeTypes = (args["mimeTypes"] as? [String]) ?? []
    allowedExts = ((args["extensions"] as? [String]) ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
    pendingResult = result
    pendingMulti = multi
    DispatchQueue.main.async {
      let vc: UIDocumentPickerViewController
      if #available(iOS 14, *) {
        var types: [UTType] = []
        for m in mimeTypes {
          if let t = UTType(mimeType: m) { types.append(t) }
        }
        if types.isEmpty { types = [.data] }
        vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
      } else {
        vc = UIDocumentPickerViewController(documentTypes: ["public.data"], in: .import)
      }
      vc.allowsMultipleSelection = multi
      vc.delegate = self
      guard let root = UIApplication.shared.delegate?.window??.rootViewController else { result(["items": []]); return }
      (root.presentedViewController ?? root).present(vc, animated: true)
    }
  }
}

extension FilePickerNative: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let tmpDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    var items: [[String: Any?]] = []
    for src in urls {
      let ext = src.pathExtension.lowercased()
      if !allowedExts.isEmpty && !allowedExts.contains(ext) { continue }
      let dest = tmpDir.appendingPathComponent("doc_\(UUID().uuidString)_\(src.lastPathComponent)")
      let ok = src.startAccessingSecurityScopedResource()
      try? FileManager.default.copyItem(at: src, to: dest)
      if ok { src.stopAccessingSecurityScopedResource() }
      let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
      let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
      items.append([
        "path": dest.path,
        "mime": "application/octet-stream",
        "size": size,
        "name": src.lastPathComponent
      ])
    }
    pendingResult?(["items": items])
    pendingResult = nil
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingResult?(["items": []])
    pendingResult = nil
  }
}
