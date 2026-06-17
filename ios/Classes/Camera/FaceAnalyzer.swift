import AVFoundation
import CoreMedia
import Foundation
import Vision

/// Runs `VNDetectFaceRectanglesRequest` on incoming CVPixelBuffers. Emits face
/// rects on [sink] at most every [minIntervalMs] (default 66 ms / ~15 Hz).
public final class MinisFaceAnalyzer {
    public typealias Sink = (_ faces: [[String: Any]]) -> Void

    private let queue = DispatchQueue(label: "minis.face")
    private let request: VNDetectFaceRectanglesRequest
    private let minIntervalMs: Double
    private var lastEmit: Double = 0
    private var sink: Sink?

    public private(set) var lastFaceRects: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []

    public init(minIntervalMs: Double = 66) {
        self.minIntervalMs = minIntervalMs
        self.request = VNDetectFaceRectanglesRequest()
    }

    public func setSink(_ s: @escaping Sink) { sink = s }

    public func process(_ sample: CMSampleBuffer) {
        let now = Date().timeIntervalSince1970 * 1000.0
        if now - lastEmit < minIntervalMs { return }
        lastEmit = now
        queue.async {
            guard let buf = CMSampleBufferGetImageBuffer(sample) else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: buf, orientation: .up, options: [:])
            do {
                try handler.perform([self.request])
                let observations = (self.request.results) ?? []
                var rects: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
                let payload: [[String: Any]] = observations.map { obs in
                    let r = obs.boundingBox
                    let normalized = (r.minX, 1.0 - r.maxY, r.width, r.height) // Vision origin = bottom-left → flip Y.
                    rects.append(normalized)
                    return [
                        "rect": [Double(normalized.0), Double(normalized.1), Double(normalized.2), Double(normalized.3)],
                        "confidence": Double(obs.confidence),
                    ]
                }
                self.lastFaceRects = rects
                let sinkRef = self.sink
                DispatchQueue.main.async { sinkRef?(payload) }
            } catch { /* swallow */ }
        }
    }
}
