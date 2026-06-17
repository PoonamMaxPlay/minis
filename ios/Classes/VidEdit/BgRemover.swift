import AVFoundation
import CoreVideo
import Vision

/// Per-frame person segmentation using Vision's
/// `VNGeneratePersonSegmentationRequest`. The host steps through the clip,
/// requests a mask per frame, and serialises the result into the same
/// atlas format produced on Android by `BgRemover.kt`.
public final class BgRemover {

  public struct MaskFrame {
    public let ptsMs: Int64
    public let width: Int
    public let height: Int
    public let data: Data
  }

  public init() {}

  public func extract(input: URL, stepMs: Int64 = 100) async throws -> [MaskFrame] {
    let asset = AVURLAsset(url: input)
    let duration = CMTimeGetSeconds(asset.duration) * 1000.0
    guard duration > 0 else { return [] }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    var out: [MaskFrame] = []
    var t: Int64 = 0
    while Double(t) < duration {
      let cmt = CMTime(value: CMTimeValue(t), timescale: 1000)
      guard let cg = try? generator.copyCGImage(at: cmt, actualTime: nil) else {
        t += stepMs; continue
      }
      let request = VNGeneratePersonSegmentationRequest()
      request.qualityLevel = .balanced
      request.outputPixelFormat = kCVPixelFormatType_OneComponent8
      let handler = VNImageRequestHandler(cgImage: cg, options: [:])
      try handler.perform([request])
      if let result = request.results?.first as? VNPixelBufferObservation {
        let pb = result.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var data = Data(count: w * h)
        if let base = CVPixelBufferGetBaseAddress(pb) {
          data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for y in 0..<h {
              let src = base.advanced(by: y * stride)
              raw.baseAddress!.advanced(by: y * w).copyMemory(from: src, byteCount: w)
            }
          }
        }
        out.append(MaskFrame(ptsMs: t, width: w, height: h, data: data))
      }
      t += stepMs
    }
    return out
  }

  public func save(frames: [MaskFrame], to url: URL) throws {
    var blob = Data()
    var magic: UInt32 = 0x4D4E4D41
    var count = UInt32(frames.count)
    blob.append(Data(bytes: &magic, count: 4))
    blob.append(Data(bytes: &count, count: 4))
    for f in frames {
      var pts = f.ptsMs
      var w = Int32(f.width)
      var h = Int32(f.height)
      var n = UInt32(f.data.count)
      blob.append(Data(bytes: &pts, count: 8))
      blob.append(Data(bytes: &w, count: 4))
      blob.append(Data(bytes: &h, count: 4))
      blob.append(Data(bytes: &n, count: 4))
      blob.append(f.data)
    }
    try blob.write(to: url)
  }
}
