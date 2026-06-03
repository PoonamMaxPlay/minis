import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Metal

/// PiP compositor + AVAssetWriter: takes two CVPixelBuffer streams (primary +
/// secondary) and writes a single H.264 MP4. Composites via CoreImage (Metal
/// backed) for simplicity; the sub-quad rectangle is decided by [layout].
@available(iOS 13.0, *)
public final class MinisMultiCamCompositor {
    public enum Layout: String { case topLeft, topRight, bottomLeft, bottomRight, sideBySide, pip25 }

    private let outURL: URL
    private let layout: Layout
    private let width: Int
    private let height: Int
    private let fps: Int

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let ciContext: CIContext
    private var startTime: CMTime?
    private let queue = DispatchQueue(label: "minis.pip.compositor")

    private var primaryBuf: CVPixelBuffer?
    private var secondaryBuf: CVPixelBuffer?

    public init(outURL: URL, layout: Layout, width: Int = 1280, height: Int = 720, fps: Int = 30) {
        self.outURL = outURL
        self.layout = layout
        self.width = width
        self.height = height
        self.fps = fps
        if let dev = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: dev)
        } else {
            self.ciContext = CIContext()
        }
    }

    public func start() throws {
        try? FileManager.default.removeItem(at: outURL)
        let w = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { throw NSError(domain: "minis.pip", code: -1) }
        w.add(i)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: i,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        w.startWriting()
        w.startSession(atSourceTime: .zero)
        writer = w
        input = i
        self.adaptor = adaptor
    }

    public func appendPrimary(_ sample: CMSampleBuffer) {
        guard let buf = CMSampleBufferGetImageBuffer(sample) else { return }
        queue.async {
            self.primaryBuf = buf
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            self.composite(at: pts)
        }
    }

    public func appendSecondary(_ sample: CMSampleBuffer) {
        guard let buf = CMSampleBufferGetImageBuffer(sample) else { return }
        queue.async { self.secondaryBuf = buf }
    }

    private func composite(at pts: CMTime) {
        guard let adaptor = adaptor, let input = input else { return }
        guard input.isReadyForMoreMediaData else { return }
        guard let primary = primaryBuf else { return }
        if startTime == nil { startTime = pts }
        let normalizedPts = CMTimeSubtract(pts, startTime!)

        let primaryImg = CIImage(cvPixelBuffer: primary)
        let scaledPrimary = primaryImg.transformed(
            by: scaleTransform(to: CGRect(x: 0, y: 0, width: width, height: height), from: primaryImg.extent))

        var combined = scaledPrimary
        if let secondary = secondaryBuf {
            let secImg = CIImage(cvPixelBuffer: secondary)
            let subRect = subQuadRect()
            combined = secImg
                .transformed(by: scaleTransform(to: subRect, from: secImg.extent))
                .composited(over: combined)
        }

        guard let pool = adaptor.pixelBufferPool else { return }
        var outBuf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuf)
        guard let dst = outBuf else { return }
        ciContext.render(combined, to: dst)
        adaptor.append(dst, withPresentationTime: normalizedPts)
    }

    private func scaleTransform(to dst: CGRect, from src: CGRect) -> CGAffineTransform {
        let sx = dst.width / src.width
        let sy = dst.height / src.height
        return CGAffineTransform(scaleX: sx, y: sy).translatedBy(x: dst.minX, y: dst.minY)
    }

    private func subQuadRect() -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        let qw = w / 4, qh = h / 4
        switch layout {
        case .topLeft:     return CGRect(x: 0, y: h - qh, width: qw, height: qh)
        case .topRight:    return CGRect(x: w - qw, y: h - qh, width: qw, height: qh)
        case .bottomLeft:  return CGRect(x: 0, y: 0, width: qw, height: qh)
        case .bottomRight: return CGRect(x: w - qw, y: 0, width: qw, height: qh)
        case .sideBySide:  return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .pip25:       return CGRect(x: w - qw, y: 0, width: qw, height: qh)
        }
    }

    public func stop(completion: @escaping (String?) -> Void) {
        queue.async {
            self.input?.markAsFinished()
            self.writer?.finishWriting {
                let ok = self.writer?.status == .completed
                DispatchQueue.main.async { completion(ok ? self.outURL.path : nil) }
            }
        }
    }
}

/// Thin AVCaptureVideoDataOutputSampleBufferDelegate that forwards every
/// sample buffer to a closure. Used to route primary/secondary streams into
/// the compositor.
public final class MinisPipDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let handler: (CMSampleBuffer) -> Void
    public init(handler: @escaping (CMSampleBuffer) -> Void) { self.handler = handler }
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) { handler(sampleBuffer) }
}
