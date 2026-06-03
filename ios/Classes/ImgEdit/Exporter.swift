import Foundation
import ImageIO
import MobileCoreServices
import UIKit
import UniformTypeIdentifiers

/// `CGImageDestination` based writer. Supports JPEG, PNG, HEIC, WebP.
/// EXIF + ICC profile is preserved when the source path is supplied.
///
/// When the Metal pipeline has produced an output texture, the encoded
/// bytes come from there via `ImageEditMetalRenderer.readbackCGImage`.
/// If the renderer hasn't run a real pass yet (skeleton phase), the
/// source file is re-encoded so the round-trip stays unbroken.
public enum Exporter {

    public static func write(
        viewId: Int64,
        sourcePath: String?,
        renderer: ImageEditMetalRenderer?,
        layers: LayerStack,
        format: String,
        quality: Int,
        maxDim: Int?,
        path: String
    ) -> [String: Any] {
        let target = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var cgImage: CGImage? = renderer?.readbackCGImage()
        var sourceMeta: CFDictionary?

        if cgImage == nil, let src = sourcePath {
            let url = URL(fileURLWithPath: src) as CFURL
            if let srcRef = CGImageSourceCreateWithURL(url, nil) {
                cgImage = CGImageSourceCreateImageAtIndex(srcRef, 0, nil)
                sourceMeta = CGImageSourceCopyPropertiesAtIndex(srcRef, 0, nil)
            }
        }

        guard var image = cgImage else {
            return ["path": "", "w": 0, "h": 0, "size": 0]
        }

        if let maxDim = maxDim {
            image = downscale(image, maxDim: maxDim) ?? image
        }

        let utType = utType(forFormat: format)
        guard let dest = CGImageDestinationCreateWithURL(
            target as CFURL, utType, 1, nil
        ) else {
            return ["path": "", "w": 0, "h": 0, "size": 0]
        }

        var opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality:
                NSNumber(value: Double(quality) / 100.0),
        ]
        if let meta = sourceMeta as? [CFString: Any] {
            if let exif = meta[kCGImagePropertyExifDictionary] {
                opts[kCGImagePropertyExifDictionary] = exif
            }
            if let icc = meta[kCGImagePropertyProfileName] {
                opts[kCGImagePropertyProfileName] = icc
            }
            if let orientation = meta[kCGImagePropertyOrientation] {
                opts[kCGImagePropertyOrientation] = orientation
            }
        }

        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        let ok = CGImageDestinationFinalize(dest)
        if !ok {
            return ["path": "", "w": 0, "h": 0, "size": 0]
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        return [
            "path": path,
            "w": image.width,
            "h": image.height,
            "size": size,
        ]
    }

    private static func utType(forFormat format: String) -> CFString {
        switch format.lowercased() {
        case "png":
            return kUTTypePNG
        case "heic":
            if #available(iOS 11.0, *) {
                return "public.heic" as CFString
            }
            return kUTTypeJPEG
        case "webp":
            if #available(iOS 14.0, *) {
                return "org.webmproject.webp" as CFString
            }
            return kUTTypeJPEG
        default:
            return kUTTypeJPEG
        }
    }

    private static func downscale(_ image: CGImage, maxDim: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        if longest <= maxDim { return image }
        let scale = Double(maxDim) / Double(longest)
        let nw = max(1, Int(Double(w) * scale))
        let nh = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(
            data: nil,
            width: nw,
            height: nh,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
