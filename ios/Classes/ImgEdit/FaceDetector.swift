import Foundation
import Vision

/// Vision framework wrapper — face landmarks for beauty/liquify and
/// person segmentation for one-shot background removal.
public enum FaceDetector {

    public static func runFaceLandmarks(viewId: Int64, sourcePath: String?) -> [[String: Any]] {
        guard let path = sourcePath,
              let image = loadCGImage(path) else { return [] }
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }
        return observations.compactMap { obs in
            guard let landmarks = obs.landmarks else { return nil }
            return [
                "boundingBox": [
                    "x": Double(obs.boundingBox.origin.x),
                    "y": Double(obs.boundingBox.origin.y),
                    "w": Double(obs.boundingBox.width),
                    "h": Double(obs.boundingBox.height),
                ],
                "allPoints": (landmarks.allPoints?.normalizedPoints ?? [])
                    .map { ["x": Double($0.x), "y": Double($0.y)] },
            ]
        }
    }

    public static func runPersonSegmentation(
        viewId: Int64, sourcePath: String?
    ) -> [String: Any] {
        guard let path = sourcePath,
              let image = loadCGImage(path) else {
            return ["status": "no_source"]
        }
        if #available(iOS 15.0, *) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ["status": "error", "message": error.localizedDescription]
            }
            guard let result = request.results?.first else {
                return ["status": "no_mask"]
            }
            return [
                "status": "ok",
                "width": result.pixelBuffer.width,
                "height": result.pixelBuffer.height,
            ]
        } else {
            return ["status": "unavailable", "reason": "iOS 15 required"]
        }
    }

    private static func loadCGImage(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

private extension CVPixelBuffer {
    var width: Int { CVPixelBufferGetWidth(self) }
    var height: Int { CVPixelBufferGetHeight(self) }
}
