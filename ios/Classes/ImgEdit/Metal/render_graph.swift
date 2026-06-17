import Foundation
import Metal
import MetalKit

/// Tracks an ordered list of render passes. Each pass binds a fragment
/// program and reads from the current "input" `MTLTexture`, writing into
/// a ping-pong target. The final output is presented to the drawable in
/// `ImageEditMetalRenderer.draw(in:)`.
final class RenderGraph {

    enum PassKind {
        case passthrough
        case adjust
        case lut
        case crop
        case overlay
    }

    struct Pass {
        let kind: PassKind
        var extra: MTLTexture? = nil
        var opacity: Float = 1.0
        var blend: Int = 0
    }

    private let device: MTLDevice
    private let library: MTLLibrary?
    private let pixelFormat: MTLPixelFormat
    private var ping: MTLTexture?
    private var pong: MTLTexture?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var sampler: MTLSamplerState?
    private var width: Int = 0
    private var height: Int = 0

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        self.pixelFormat = pixelFormat
        self.library = device.makeDefaultLibrary()
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sd.rAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sd)
        compile()
    }

    private func compile() {
        guard let library = library else { return }
        let mapping: [(String, String, String)] = [
            ("passthrough", "minis_quad_vs", "minis_passthrough"),
            ("adjust",      "minis_quad_vs", "minis_adjust"),
            ("lut",         "minis_quad_vs", "minis_lut3d"),
            ("overlay",     "minis_quad_vs", "minis_overlay_composite"),
            ("crop",        "minis_crop_vs", "minis_crop"),
        ]
        for (name, vs, fs) in mapping {
            guard let vfn = library.makeFunction(name: vs),
                  let ffn = library.makeFunction(name: fs) else { continue }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = pixelFormat
            if let p = try? device.makeRenderPipelineState(descriptor: desc) {
                pipelines[name] = p
            }
        }
    }

    func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if width == self.width && height == self.height { return }
        self.width = width
        self.height = height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height,
            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        ping = device.makeTexture(descriptor: desc)
        pong = device.makeTexture(descriptor: desc)
    }

    /// Render the graph. Returns the final texture (also written to the
    /// drawable's color attachment).
    func execute(commandBuffer: MTLCommandBuffer,
                 base: MTLTexture,
                 passes: [Pass],
                 drawableTexture: MTLTexture?,
                 adjustParams: AdjustParamsBuffer,
                 lutParams: LutParamsBuffer,
                 lutTexture: MTLTexture?,
                 cropParams: CropParamsBuffer) -> MTLTexture? {
        guard let ping = ping, let pong = pong, let sampler = sampler else { return nil }
        var current = base
        var target = ping
        var spare = pong

        // Apply crop first if active.
        if cropParams.active != 0, let p = pipelines["crop"] {
            run(commandBuffer: commandBuffer, pipeline: p,
                inputs: [current], target: target, sampler: sampler) { enc in
                var cp = cropParams
                enc.setVertexBytes(&cp, length: MemoryLayout<CropParamsBuffer>.stride,
                                   index: 0)
            }
            swap(&current, &target); swap(&target, &spare)
        }

        if adjustParams.hasAny, let p = pipelines["adjust"] {
            run(commandBuffer: commandBuffer, pipeline: p,
                inputs: [current], target: target, sampler: sampler) { enc in
                var ap = adjustParams
                enc.setFragmentBytes(&ap, length: MemoryLayout<AdjustParamsBuffer>.stride,
                                     index: 0)
            }
            swap(&current, &target); swap(&target, &spare)
        }

        if let lt = lutTexture, lutParams.intensity > 0, lutParams.size > 0,
           let p = pipelines["lut"] {
            run(commandBuffer: commandBuffer, pipeline: p,
                inputs: [current, lt], target: target, sampler: sampler) { enc in
                var lp = lutParams
                enc.setFragmentBytes(&lp, length: MemoryLayout<LutParamsBuffer>.stride,
                                     index: 0)
            }
            swap(&current, &target); swap(&target, &spare)
        }

        for pass in passes {
            guard let extra = pass.extra, let p = pipelines["overlay"] else { continue }
            run(commandBuffer: commandBuffer, pipeline: p,
                inputs: [current, extra], target: target, sampler: sampler) { enc in
                var op = OverlayParams(opacity: pass.opacity, blend: Int32(pass.blend))
                enc.setFragmentBytes(&op, length: MemoryLayout<OverlayParams>.stride,
                                     index: 0)
            }
            swap(&current, &target); swap(&target, &spare)
        }

        if let drawable = drawableTexture, let p = pipelines["passthrough"] {
            run(commandBuffer: commandBuffer, pipeline: p,
                inputs: [current], target: drawable, sampler: sampler) { _ in }
        }
        return current
    }

    private func run(commandBuffer: MTLCommandBuffer,
                     pipeline: MTLRenderPipelineState,
                     inputs: [MTLTexture],
                     target: MTLTexture,
                     sampler: MTLSamplerState,
                     configure: (MTLRenderCommandEncoder) -> Void) {
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = target
        pd.colorAttachments[0].loadAction = .clear
        pd.colorAttachments[0].storeAction = .store
        pd.colorAttachments[0].clearColor =
            MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pd)
        else { return }
        enc.setRenderPipelineState(pipeline)
        for (i, tex) in inputs.enumerated() {
            enc.setFragmentTexture(tex, index: i)
        }
        enc.setFragmentSamplerState(sampler, index: 0)
        configure(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

struct AdjustParamsBuffer {
    var exposure: Float = 0
    var contrast: Float = 0
    var saturation: Float = 1
    var temperature: Float = 0
    var tint: Float = 0
    var sharpen: Float = 0
    var clarity: Float = 0
    var dehaze: Float = 0
    var px: SIMD2<Float> = SIMD2<Float>(0, 0)

    var hasAny: Bool {
        return exposure != 0 || contrast != 0 || saturation != 1 ||
               temperature != 0 || tint != 0 || sharpen != 0 ||
               clarity != 0 || dehaze != 0
    }
}

struct LutParamsBuffer {
    var intensity: Float = 0
    var size: Float = 0
}

struct CropParamsBuffer {
    var h: simd_float3x3 = matrix_identity_float3x3
    var active: Int32 = 0
}

struct OverlayParams {
    var opacity: Float
    var blend: Int32
}
