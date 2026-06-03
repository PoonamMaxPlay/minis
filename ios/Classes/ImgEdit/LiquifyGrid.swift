import Foundation
import Metal
import simd

/// 32×32 displacement grid mutated by liquify brush ops. Uploaded into
/// the `warp` texture sampled by `Metal/liquify.metal`.
public final class LiquifyGrid {

    public enum BrushKind: String {
        case push, pull, pinch, bloat, twirl
    }

    public static let dim: Int = 32

    private(set) var dx: [Float]
    private(set) var dy: [Float]

    public init() {
        self.dx = [Float](repeating: 0, count: LiquifyGrid.dim * LiquifyGrid.dim)
        self.dy = [Float](repeating: 0, count: LiquifyGrid.dim * LiquifyGrid.dim)
    }

    public func apply(kind: BrushKind, center: SIMD2<Float>,
                      direction: SIMD2<Float>, radius: Float, strength: Float) {
        let d = LiquifyGrid.dim
        for gy in 0..<d {
            for gx in 0..<d {
                let u = (Float(gx) + 0.5) / Float(d)
                let v = (Float(gy) + 0.5) / Float(d)
                let p = SIMD2<Float>(u, v) - center
                let dist = simd_length(p)
                if dist > radius { continue }
                let w = expGauss(dist / radius) * strength
                let idx = gy * d + gx
                switch kind {
                case .push:
                    dx[idx] += direction.x * w
                    dy[idx] += direction.y * w
                case .pull:
                    dx[idx] -= direction.x * w
                    dy[idx] -= direction.y * w
                case .pinch:
                    dx[idx] -= p.x * w
                    dy[idx] -= p.y * w
                case .bloat:
                    dx[idx] += p.x * w
                    dy[idx] += p.y * w
                case .twirl:
                    let theta = w * .pi
                    let c = cos(theta), s = sin(theta)
                    let np = SIMD2<Float>(p.x * c - p.y * s, p.x * s + p.y * c)
                    dx[idx] += (np.x - p.x)
                    dy[idx] += (np.y - p.y)
                }
            }
        }
    }

    public func reset() {
        for i in 0..<dx.count { dx[i] = 0; dy[i] = 0 }
    }

    public func uploadTexture(device: MTLDevice) -> MTLTexture? {
        let d = LiquifyGrid.dim
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float, width: d, height: d, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var data = [UInt16](repeating: 0, count: d * d * 2)
        for i in 0..<(d * d) {
            data[i * 2 + 0] = floatToHalf(dx[i])
            data[i * 2 + 1] = floatToHalf(dy[i])
        }
        data.withUnsafeBufferPointer { ptr in
            let region = MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: d, height: d, depth: 1))
            tex.replace(region: region, mipmapLevel: 0,
                        withBytes: ptr.baseAddress!,
                        bytesPerRow: d * 4)
        }
        return tex
    }

    private func expGauss(_ x: Float) -> Float {
        return exp(-x * x * 4.0)
    }

    private func floatToHalf(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let val = (bits & 0x7FFFFFFF) &+ 0x1000
        if val >= 0x47800000 { return sign | 0x7C00 }
        if val >= 0x38800000 {
            return sign | UInt16(((val - 0x38000000) >> 13) & 0xFFFF)
        }
        if val < 0x33000000 { return sign }
        let v = (val & 0x7FFFFFFF) >> 23
        let shift = 125 &- Int(v)
        let mantissa = (val & 0x7FFFFF) | 0x800000
        return sign | UInt16((mantissa >> (shift + 1)) & 0xFFFF)
    }
}
