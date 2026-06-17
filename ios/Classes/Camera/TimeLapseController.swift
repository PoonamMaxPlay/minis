import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// Interval shutter + MP4 stitcher. Captures stills via [stillCallback], then
/// stitches accumulated JPEG paths into a single H.264 MP4 via AVAssetWriter
/// with a CVPixelBuffer adaptor.
public final class MinisTimeLapseController {
    public typealias StillCallback = (_ outPath: String, _ done: @escaping (Bool) -> Void) -> Void

    private let stillCallback: StillCallback
    private let queue = DispatchQueue(label: "minis.timelapse")
    private var timer: DispatchSourceTimer?
    private var started = Date()
    private var duration: TimeInterval = 0
    private var workDir: URL
    private(set) public var frames: [String] = []
    private var onDone: (([String]) -> Void)?
    private var running = false

    public init(workDir: URL, stillCallback: @escaping StillCallback) {
        self.workDir = workDir
        self.stillCallback = stillCallback
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    public func start(intervalMs: Int, durationMs: Int, onComplete: @escaping ([String]) -> Void) {
        guard !running else { return }
        running = true
        frames.removeAll()
        started = Date()
        duration = TimeInterval(durationMs) / 1000.0
        onDone = onComplete
        let interval = TimeInterval(intervalMs) / 1000.0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.started) >= self.duration {
                self.stop()
                return
            }
            let p = self.workDir.appendingPathComponent("minis_tl_\(Int(Date().timeIntervalSince1970 * 1000)).jpg").path
            self.stillCallback(p) { ok in
                if ok, FileManager.default.fileExists(atPath: p) {
                    self.queue.async { self.frames.append(p) }
                }
            }
        }
        t.resume()
        timer = t
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        let snap = frames
        let cb = onDone
        onDone = nil
        DispatchQueue.main.async { cb?(snap) }
    }

    /// Encode accumulated JPEGs into a single MP4 (h264) at [fps].
    public func stitchToMp4(
        outPath: String,
        fps: Int = 30,
        keepStagedJpegs: Bool = false,
        completion: @escaping (String?) -> Void
    ) {
        let frameSnap = frames
        queue.async {
            guard !frameSnap.isEmpty else { completion(nil); return }
            guard let firstImg = UIImage(contentsOfFile: frameSnap.first!), let firstCg = firstImg.cgImage
            else { completion(nil); return }
            let w = firstCg.width - (firstCg.width % 2)
            let h = firstCg.height - (firstCg.height % 2)
            let url = URL(fileURLWithPath: outPath)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { completion(nil); return }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let pba: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pba)
            guard writer.canAdd(input) else { completion(nil); return }
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let cs = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            for (idx, path) in frameSnap.enumerated() {
                guard let img = UIImage(contentsOfFile: path), let cg = img.cgImage else { continue }
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                var pixel: CVPixelBuffer?
                CVPixelBufferCreate(
                    nil, w, h, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
                guard let buf = pixel else { continue }
                CVPixelBufferLockBaseAddress(buf, [])
                if let ctx = CGContext(
                    data: CVPixelBufferGetBaseAddress(buf),
                    width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                    space: cs, bitmapInfo: bitmapInfo)
                {
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
                CVPixelBufferUnlockBaseAddress(buf, [])
                let pts = CMTime(value: CMTimeValue(idx), timescale: CMTimeScale(fps))
                adaptor.append(buf, withPresentationTime: pts)
            }
            input.markAsFinished()
            writer.finishWriting {
                let ok = writer.status == .completed
                if ok, !keepStagedJpegs {
                    for p in frameSnap { try? FileManager.default.removeItem(atPath: p) }
                }
                DispatchQueue.main.async { completion(ok ? outPath : nil) }
            }
        }
    }
}
