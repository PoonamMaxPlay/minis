import Foundation
import UIKit
import CoreGraphics
import CoreText

/// CPU rasterizer for sticker / text / emoji layers. Mirrors the Android
/// counterpart. The renderer wraps the produced `CGImage` as `MTLTexture`.
public enum StickerLayer {

    public static func paintSticker(canvasW: Int, canvasH: Int,
                                    stickerPath: String,
                                    transform: [Double]?) -> CGImage? {
        guard canvasW > 0, canvasH > 0 else { return nil }
        guard let img = UIImage(contentsOfFile: stickerPath)?.cgImage else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: canvasW * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        applyTransform(ctx, transform, canvasW: canvasW, canvasH: canvasH)
        let w = img.width
        let h = img.height
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }

    public static func paintText(canvasW: Int, canvasH: Int,
                                 text: String, font: UIFont,
                                 color: UIColor, transform: [Double]?,
                                 strokeColor: UIColor? = nil,
                                 strokeWidth: CGFloat = 0) -> CGImage? {
        guard canvasW > 0, canvasH > 0 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: canvasW * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        applyTransform(ctx, transform, canvasW: canvasW, canvasH: canvasH)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if let sc = strokeColor, strokeWidth > 0 {
            attrs[.strokeColor] = sc
            attrs[.strokeWidth] = -strokeWidth
        }
        let attr = NSAttributedString(string: text, attributes: attrs)
        let size = attr.size()
        attr.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        return ctx.makeImage()
    }

    public static func paintEmoji(canvasW: Int, canvasH: Int,
                                  codePoint: Int, sizePx: CGFloat,
                                  transform: [Double]?) -> CGImage? {
        guard let scalar = Unicode.Scalar(codePoint) else { return nil }
        let s = String(scalar)
        let f = UIFont.systemFont(ofSize: sizePx)
        return paintText(canvasW: canvasW, canvasH: canvasH,
                         text: s, font: f, color: .white, transform: transform)
    }

    private static func applyTransform(_ ctx: CGContext, _ t: [Double]?,
                                       canvasW: Int, canvasH: Int) {
        if let t = t, t.count >= 6 {
            let tx = CGFloat(t[0]) * CGFloat(canvasW)
            let ty = CGFloat(t[1]) * CGFloat(canvasH)
            let sx = CGFloat(t[2])
            let sy = CGFloat(t[3])
            let rot = CGFloat(t[4]) * .pi / 180.0
            ctx.translateBy(x: tx, y: ty)
            ctx.rotate(by: rot)
            ctx.scaleBy(x: sx, y: sy)
        } else {
            ctx.translateBy(x: CGFloat(canvasW) / 2.0, y: CGFloat(canvasH) / 2.0)
        }
    }
}
