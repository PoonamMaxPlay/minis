import Foundation
import Metal
import MetalKit
import simd
import UIKit
import CoreImage

/// `MTKViewDelegate` driving the image editor render graph. Owns the base
/// texture, LUT texture, per-layer extra textures, and the live uniform
/// buffers fed to the Metal shaders defined under `Metal/`.
public final class ImageEditMetalRenderer: NSObject, MTKViewDelegate {

    public let device: MTLDevice
    public let viewId: Int64
    public weak var hostView: MTKView?

    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext
    private var graph: RenderGraph
    private var baseTexture: MTLTexture?
    private var lutTexture: MTLTexture?
    private var sourceCGImage: CGImage?
    private var needsRender: Bool = true

    private var adjustParams = AdjustParamsBuffer()
    private var lutParams = LutParamsBuffer()
    private var cropParams = CropParamsBuffer()
    private var lutPath: String = ""
    private var extras: [RenderGraph.Pass] = []

    public init(device: MTLDevice, viewId: Int64) {
        self.device = device
        self.viewId = viewId
        self.commandQueue = device.makeCommandQueue()
        self.ciContext = CIContext(mtlDevice: device)
        self.graph = RenderGraph(device: device, pixelFormat: .bgra8Unorm)
        super.init()
    }

    public func initSession(sourcePath: String?, width: Int, height: Int) {
        loadBaseImage(path: sourcePath)
    }

    public func loadBaseImage(path: String?) {
        guard let path = path else { return }
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return }
        sourceCGImage = cg
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(
                value: MTLTextureUsage.shaderRead.rawValue
                    | MTLTextureUsage.renderTarget.rawValue),
        ]
        baseTexture = try? loader.newTexture(cgImage: cg, options: options)
        if let tex = baseTexture {
            graph.resize(width: tex.width, height: tex.height)
            adjustParams.px = SIMD2<Float>(1.0 / Float(tex.width), 1.0 / Float(tex.height))
        }
        needsRender = true
        hostView?.setNeedsDisplay()
    }

    public func setNeedsRender() {
        needsRender = true
        hostView?.setNeedsDisplay()
    }

    public func applyAdjust(key: String, value: Double) {
        let v = Float(value)
        switch key {
        case "exposure": adjustParams.exposure = v
        case "contrast": adjustParams.contrast = v
        case "saturation": adjustParams.saturation = v
        case "temperature": adjustParams.temperature = v
        case "tint": adjustParams.tint = v
        case "sharpen": adjustParams.sharpen = v
        case "clarity": adjustParams.clarity = v
        case "dehaze": adjustParams.dehaze = v
        default: break
        }
        setNeedsRender()
    }

    public func applyFilter(lutPath: String, intensity: Double) {
        if lutPath != self.lutPath {
            self.lutPath = lutPath
            lutTexture = nil
            if !lutPath.isEmpty {
                if let parsed = LutCubeParser.parse(path: lutPath) {
                    lutTexture = LutCubeParser.upload(parsed, device: device)
                    lutParams.size = Float(parsed.size)
                }
            } else {
                lutParams.size = 0
            }
        }
        lutParams.intensity = Float(intensity)
        setNeedsRender()
    }

    public func applyCrop(rect: [String: Any], rotationDeg: Double, persp: [Double]?) {
        var h = matrix_identity_float3x3
        if let persp = persp, persp.count == 8 {
            h = Self.solveHomography(persp)
        } else {
            let x = Float((rect["x"] as? Double) ?? 0)
            let y = Float((rect["y"] as? Double) ?? 0)
            let w = Float((rect["w"] as? Double) ?? 1)
            let hh = Float((rect["h"] as? Double) ?? 1)
            h = Self.cropMatrix(x: x, y: y, w: w, h: hh, rotationDeg: Float(rotationDeg))
        }
        cropParams.h = h
        cropParams.active = 1
        setNeedsRender()
    }

    public func brushStroke(args: [String: Any]) { setNeedsRender() }
    public func spotHeal(args: [String: Any])    { setNeedsRender() }
    public func liquify(args: [String: Any])     { setNeedsRender() }
    public func beautify(args: [String: Any])    { setNeedsRender() }

    public func setMaskTexture(_ texture: MTLTexture?) {
        var pass = RenderGraph.Pass(kind: .overlay, extra: texture, opacity: 1.0, blend: 0)
        pass.extra = texture
        extras.append(pass)
        setNeedsRender()
    }

    public func readbackCGImage() -> CGImage? {
        guard let base = baseTexture else { return sourceCGImage }
        guard let queue = commandQueue,
              let buffer = queue.makeCommandBuffer() else { return sourceCGImage }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: base.width, height: base.height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        guard let drawable = device.makeTexture(descriptor: desc) else {
            return sourceCGImage
        }
        _ = graph.execute(
            commandBuffer: buffer, base: base, passes: extras,
            drawableTexture: drawable, adjustParams: adjustParams,
            lutParams: lutParams, lutTexture: lutTexture,
            cropParams: cropParams
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        return Self.textureToCGImage(drawable, ci: ciContext)
    }

    public func dispose() {
        baseTexture = nil
        lutTexture = nil
        sourceCGImage = nil
        extras.removeAll()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        graph.resize(width: Int(size.width), height: Int(size.height))
        needsRender = true
    }

    public func draw(in view: MTKView) {
        guard needsRender,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let queue = commandQueue,
              let buffer = queue.makeCommandBuffer()
        else { return }
        defer {
            buffer.present(drawable)
            buffer.commit()
            needsRender = false
        }
        _ = descriptor // graph encodes its own pass descriptors
        if let base = baseTexture {
            _ = graph.execute(
                commandBuffer: buffer, base: base, passes: extras,
                drawableTexture: drawable.texture,
                adjustParams: adjustParams, lutParams: lutParams,
                lutTexture: lutTexture, cropParams: cropParams)
        } else {
            if let enc = buffer.makeRenderCommandEncoder(descriptor: descriptor) {
                enc.endEncoding()
            }
        }
    }

    // MARK: - homography helpers

    private static func solveHomography(_ persp: [Double]) -> simd_float3x3 {
        let src: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        let dst: [(Double, Double)] = [
            (persp[0], persp[1]), (persp[2], persp[3]),
            (persp[4], persp[5]), (persp[6], persp[7])
        ]
        var A = Array(repeating: Array(repeating: 0.0, count: 9), count: 8)
        for i in 0..<4 {
            let (sx, sy) = src[i]
            let (dx, dy) = dst[i]
            let rx = i * 2
            let ry = rx + 1
            A[rx][0] = sx; A[rx][1] = sy; A[rx][2] = 1
            A[rx][6] = -sx * dx; A[rx][7] = -sy * dx
            A[rx][8] = dx
            A[ry][3] = sx; A[ry][4] = sy; A[ry][5] = 1
            A[ry][6] = -sx * dy; A[ry][7] = -sy * dy
            A[ry][8] = dy
        }
        // Gaussian elimination.
        let n = 8
        for i in 0..<n {
            var piv = i
            var best = abs(A[i][i])
            for r in (i + 1)..<n where abs(A[r][i]) > best {
                best = abs(A[r][i]); piv = r
            }
            if best < 1e-12 { return matrix_identity_float3x3 }
            if piv != i { A.swapAt(i, piv) }
            for r in (i + 1)..<n {
                let k = A[r][i] / A[i][i]
                for c in i..<(n + 1) { A[r][c] -= k * A[i][c] }
            }
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = A[i][n]
            for c in (i + 1)..<n { s -= A[i][c] * x[c] }
            x[i] = s / A[i][i]
        }
        var m = matrix_identity_float3x3
        m.columns.0 = SIMD3<Float>(Float(x[0]), Float(x[3]), Float(x[6]))
        m.columns.1 = SIMD3<Float>(Float(x[1]), Float(x[4]), Float(x[7]))
        m.columns.2 = SIMD3<Float>(Float(x[2]), Float(x[5]), 1.0)
        return m
    }

    private static func cropMatrix(x: Float, y: Float, w: Float, h: Float,
                                   rotationDeg: Float) -> simd_float3x3 {
        let ww = w == 0 ? 1.0 : w
        let hh = h == 0 ? 1.0 : h
        let cx = x + ww * 0.5
        let cy = y + hh * 0.5
        let rad = rotationDeg * .pi / 180.0
        let c = cos(rad)
        let s = sin(rad)
        var m = matrix_identity_float3x3
        m.columns.0 = SIMD3<Float>(ww * c,  hh * s, 0)
        m.columns.1 = SIMD3<Float>(-ww * s, hh * c, 0)
        m.columns.2 = SIMD3<Float>(cx, cy, 1)
        return m
    }

    private static func textureToCGImage(_ tex: MTLTexture, ci: CIContext) -> CGImage? {
        let opts: [CIImageOption: Any] = [.colorSpace: CGColorSpaceCreateDeviceRGB()]
        guard let img = CIImage(mtlTexture: tex, options: opts) else { return nil }
        let h = CGFloat(tex.height)
        let flipped = img.transformed(by: CGAffineTransform(translationX: 0, y: h)
                                        .scaledBy(x: 1, y: -1))
        return ci.createCGImage(flipped, from: flipped.extent)
    }
}

// MARK: - LUT parser bridge

enum LutCubeParser {
    struct Parsed {
        let size: Int
        let data: [Float] // size^3 * 3
    }

    static func parse(path: String) -> Parsed? {
        guard let text = try? String(contentsOfFile: path) else { return nil }
        var size = 0
        var values: [Float] = []
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") ||
                line.hasPrefix("DOMAIN_MIN") || line.hasPrefix("DOMAIN_MAX") {
                continue
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(separator: " ")
                if parts.count >= 2 { size = Int(parts[1]) ?? 0 }
                continue
            }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            if parts.count == 3 {
                values.append(contentsOf: parts)
            }
        }
        guard size > 0, values.count == size * size * size * 3 else { return nil }
        return Parsed(size: size, data: values)
    }

    static func upload(_ parsed: Parsed, device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = parsed.size
        desc.height = parsed.size
        desc.depth = parsed.size
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        // Repack RGB → RGBA16F per the texture's row/slice pitch.
        let rgba16: [Float] = {
            var out = [Float](repeating: 0, count: parsed.size * parsed.size * parsed.size * 4)
            for i in 0..<(parsed.size * parsed.size * parsed.size) {
                out[i * 4 + 0] = parsed.data[i * 3 + 0]
                out[i * 4 + 1] = parsed.data[i * 3 + 1]
                out[i * 4 + 2] = parsed.data[i * 3 + 2]
                out[i * 4 + 3] = 1.0
            }
            return out
        }()
        let half = rgba16.map { Self.floatToHalf($0) }
        let bytesPerRow = parsed.size * 4 * 2
        let bytesPerSlice = bytesPerRow * parsed.size
        half.withUnsafeBufferPointer { ptr in
            let region = MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: parsed.size, height: parsed.size, depth: parsed.size))
            tex.replace(region: region, mipmapLevel: 0, slice: 0,
                        withBytes: ptr.baseAddress!,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: bytesPerSlice)
        }
        return tex
    }

    /// Float → IEEE 754 half-precision.
    private static func floatToHalf(_ f: Float) -> UInt16 {
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
