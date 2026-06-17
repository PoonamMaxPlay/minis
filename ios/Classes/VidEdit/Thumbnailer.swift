import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Frame-accurate thumbnail generator. Uses `AVAssetImageGenerator` (which
/// transparently dispatches to VideoToolbox HW decoders) and caches each
/// JPEG under `cachesDir/vidthumb/<hash>/<i>.jpg`.
enum Thumbnailer {

  static func strip(path: String, count: Int, width: Int, height: Int) -> [FlutterStandardTypedData] {
    guard count > 0 else { return [] }
    let n = max(1, count)
    let dir = cacheDir(path: path, n: n, w: width, h: height)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let durationSec = CMTimeGetSeconds(asset.duration)
    guard durationSec > 0 else { return [] }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: width, height: height)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var out: [FlutterStandardTypedData] = []
    out.reserveCapacity(n)
    for i in 0..<n {
      let cacheFile = "\(dir)/t_\(i).jpg"
      if FileManager.default.fileExists(atPath: cacheFile),
         let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)) {
        out.append(FlutterStandardTypedData(bytes: data))
        continue
      }
      let t = CMTime(seconds: durationSec * Double(i) / Double(n), preferredTimescale: 600)
      do {
        let cg = try generator.copyCGImage(at: t, actualTime: nil)
        if let data = jpegEncode(cg: cg, quality: 0.8) {
          try? data.write(to: URL(fileURLWithPath: cacheFile))
          out.append(FlutterStandardTypedData(bytes: data))
        }
      } catch {
        continue
      }
    }
    return out
  }

  static func single(path: String, atMs: Int64, width: Int, height: Int) -> FlutterStandardTypedData? {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: width, height: height)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let t = CMTime(value: CMTimeValue(atMs), timescale: 1000)
    guard let cg = try? gen.copyCGImage(at: t, actualTime: nil),
          let data = jpegEncode(cg: cg, quality: 0.85) else {
      return nil
    }
    return FlutterStandardTypedData(bytes: data)
  }

  private static func jpegEncode(cg: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    let jpegType = "public.jpeg" as CFString
    guard let dest = CGImageDestinationCreateWithData(data, jpegType, 1, nil) else { return nil }
    let props: NSDictionary = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, cg, props)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
  }

  private static func cacheDir(path: String, n: Int, w: Int, h: Int) -> String {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let seed = "\(path)|\(mtime)|\(n)|\(w)x\(h)".data(using: .utf8) ?? Data()
    let hash = seed.fnv1a()
    let root = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    return "\(root)/vidthumb/\(hash)"
  }
}

private extension Data {
  func fnv1a() -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in self {
      h ^= UInt64(byte)
      h = h &* 0x100000001b3
    }
    return String(h, radix: 16)
  }
}
