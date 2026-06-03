import Foundation
import CoreVideo
import Metal
import Vision
import CoreImage

/// Person segmentation + mask texture upload. Uses Vision's
/// `VNGeneratePersonSegmentationRequest` on iOS 15+. Falls back to the
/// stub status returned by `FaceDetector.runPersonSegmentation` on
/// older versions.
public enum BackgroundRemover {

    public static func produceMaskTexture(
        device: MTLDevice, sourcePath: String
    ) -> (texture: MTLTexture?, width: Int, height: Int) {
        guard let cg = loadCG(sourcePath) else { return (nil, 0, 0) }
        if #available(iOS 15.0, *) {
            let req = VNGeneratePersonSegmentationRequest()
            req.qualityLevel = .accurate
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
            guard let mask = req.results?.first?.pixelBuffer else {
                return (nil, 0, 0)
            }
            return uploadMask(mask, device: device)
        }
        return (nil, 0, 0)
    }

    private static func loadCG(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func uploadMask(_ buf: CVPixelBuffer,
                                   device: MTLDevice) -> (MTLTexture?, Int, Int) {
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return (nil, 0, 0) }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            return (nil, w, h)
        }
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: w, height: h, depth: 1))
        tex.replace(region: region, mipmapLevel: 0,
                    withBytes: base, bytesPerRow: stride)
        return (tex, w, h)
    }
}
