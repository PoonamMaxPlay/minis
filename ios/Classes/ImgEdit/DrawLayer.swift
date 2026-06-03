import Foundation
import UIKit
import CoreGraphics

/// CPU raster cache for draw / brush layers. Strokes are stamped into a
/// `CGContext`; the resulting image is uploaded as `MTLTexture` by the
/// renderer.
public final class DrawLayer {

    public let width: Int
    public let height: Int
    private let context: CGContext

    public init?(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        let bpc = 8
        let bpr = self.width * 4
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: self.width, height: self.height,
            bitsPerComponent: bpc, bytesPerRow: bpr,
            space: space, bitmapInfo: info)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: self.width, height: self.height))
        self.context = ctx
    }

    public func stroke(points: [[String: Any]], color: UIColor,
                       size: CGFloat, hardness: CGFloat, eraser: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        if eraser {
            context.setBlendMode(.clear)
            context.setFillColor(UIColor.black.cgColor)
        } else {
            context.setBlendMode(.normal)
            context.setFillColor(color.cgColor)
        }
        let radius = max(1.0, size * 0.5)
        let spacing = max(1.0, size * 0.25)
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            guard let ax = (a["x"] as? CGFloat) ?? (a["x"] as? Double).map({CGFloat($0)}),
                  let ay = (a["y"] as? CGFloat) ?? (a["y"] as? Double).map({CGFloat($0)}),
                  let bx = (b["x"] as? CGFloat) ?? (b["x"] as? Double).map({CGFloat($0)}),
                  let by = (b["y"] as? CGFloat) ?? (b["y"] as? Double).map({CGFloat($0)})
            else { continue }
            let pa = ((a["pressure"] as? Double) ?? 1.0)
            let pb = ((b["pressure"] as? Double) ?? 1.0)
            let dist = hypot(bx - ax, by - ay)
            let steps = max(1, Int(dist / spacing))
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let x = ax + (bx - ax) * t
                let y = ay + (by - ay) * t
                let pr = CGFloat(pa + (pb - pa) * Double(t))
                let alpha = max(0, min(1, pr))
                let falloff = hardness < 1 ? hardness + (1 - hardness) * 0.5 : 1.0
                context.setAlpha(alpha * falloff)
                context.fillEllipse(in: CGRect(
                    x: x - radius, y: y - radius,
                    width: radius * 2, height: radius * 2))
            }
        }
    }

    public func cgImage() -> CGImage? { context.makeImage() }
}
