import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import MetalKit

/// Metal-backed `AVVideoCompositing` for the iOS preview / GPU path.
///
/// Mirrors the Android `gl_compositor.cpp` model: each clip is sampled
/// through a transform matrix; transitions blend pairs of frames; one
/// 3D-LUT pass applies the active filter. Real-time uniforms (transition
/// progress, transform, lut amount) come from the `Timeline` and are pushed
/// through `AVVideoCompositionInstruction.layerInstructions`.
@objc public class MetalCompositor: NSObject, AVVideoCompositing {

  public var sourcePixelBufferAttributes: [String: Any]? = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]

  public var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let library: MTLLibrary?
  private var pipelines: [String: MTLRenderPipelineState] = [:]
  private var textureCache: CVMetalTextureCache?
  private let renderContextLock = NSLock()
  private var renderContext: AVVideoCompositionRenderContext?

  public override init() {
    guard let device = MTLCreateSystemDefaultDevice() else {
      fatalError("Metal device unavailable")
    }
    self.device = device
    self.queue = device.makeCommandQueue()!
    self.library = device.makeDefaultLibrary()
    super.init()
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    buildPipelines()
  }

  // MARK: - AVVideoCompositing

  public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    renderContextLock.lock()
    renderContext = newRenderContext
    renderContextLock.unlock()
  }

  public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    autoreleasepool {
      let pool = request.renderContext.newPixelBuffer()
      guard let dst = pool else {
        request.finish(with: NSError(domain: "MetalCompositor", code: -1))
        return
      }

      let instr = request.videoCompositionInstruction as? Instruction
      let progress = instr?.progress ?? 0
      let transitionName = instr?.transition ?? ""
      let lutAmount = instr?.lutAmount ?? 0.0

      var sourceA: CVPixelBuffer?
      var sourceB: CVPixelBuffer?
      let ids = request.sourceTrackIDs
      if ids.count >= 1 { sourceA = request.sourceFrame(byTrackID: ids[0].int32Value) }
      if ids.count >= 2 { sourceB = request.sourceFrame(byTrackID: ids[1].int32Value) }

      if let a = sourceA {
        compose(into: dst, a: a, b: sourceB, transition: transitionName, progress: progress, lutAmount: lutAmount)
      }
      request.finish(withComposedVideoFrame: dst)
    }
  }

  // MARK: - Pipelines

  private func buildPipelines() {
    let names: [(String, String)] = [
      ("passthrough", "ps_passthrough"),
      ("crossfade",   "ps_crossfade"),
      ("dip",         "ps_dip"),
      ("slide",       "ps_slide"),
      ("push",        "ps_push"),
      ("zoom",        "ps_zoom"),
      ("glitch",      "ps_glitch"),
      ("curves",      "ps_curves"),
    ]
    guard let lib = library, let vs = lib.makeFunction(name: "vs_quad") else { return }
    for (key, fs) in names {
      guard let frag = lib.makeFunction(name: fs) else { continue }
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = vs
      desc.fragmentFunction = frag
      desc.colorAttachments[0].pixelFormat = .bgra8Unorm
      if let p = try? device.makeRenderPipelineState(descriptor: desc) {
        pipelines[key] = p
      }
    }
  }

  // MARK: - Compose

  private func compose(into dst: CVPixelBuffer, a: CVPixelBuffer, b: CVPixelBuffer?,
                       transition: String, progress: Float, lutAmount: Float) {
    guard let cache = textureCache,
          let texA = texture(from: a, cache: cache),
          let texDst = texture(from: dst, cache: cache) else { return }
    let texB = b.flatMap { texture(from: $0, cache: cache) }
    let pipelineKey = (texB != nil && !transition.isEmpty) ? transition : "passthrough"
    let pipeline = pipelines[pipelineKey] ?? pipelines["passthrough"]
    guard let pipeline = pipeline else { return }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texDst
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.colorAttachments[0].storeAction = .store

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(texA, index: 0)
    if let b = texB { enc.setFragmentTexture(b, index: 1) }
    var uniforms = (progress, lutAmount, Float(0), Float(0))
    enc.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
  }

  private func texture(from buffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
    let w = CVPixelBufferGetWidth(buffer)
    let h = CVPixelBufferGetHeight(buffer)
    var out: CVMetalTexture?
    let rc = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, w, h, 0, &out)
    guard rc == kCVReturnSuccess, let cv = out else { return nil }
    return CVMetalTextureGetTexture(cv)
  }

  public func cancelAllPendingVideoCompositionRequests() {
    queue.insertDebugCaptureBoundary()
  }
}

@objc public class Instruction: NSObject, AVVideoCompositionInstructionProtocol {
  public let timeRange: CMTimeRange
  public let enablePostProcessing: Bool = false
  public let containsTweening: Bool = true
  public let requiredSourceTrackIDs: [NSValue]?
  public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

  public var progress: Float = 0
  public var transition: String = ""
  public var lutAmount: Float = 0

  public init(timeRange: CMTimeRange, sourceTrackIDs: [Int32]) {
    self.timeRange = timeRange
    self.requiredSourceTrackIDs = sourceTrackIDs.map { NSNumber(value: $0) }
    super.init()
  }
}
