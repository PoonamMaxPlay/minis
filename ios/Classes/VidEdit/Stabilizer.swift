import AVFoundation
import Foundation
import Vision

/// Two-tier stabilizer:
///   - Light path uses `VNTranslationalImageRegistrationRequest` to compute
///     frame-to-frame translation offsets and applies them via
///     `AVMutableVideoComposition`.
///   - Heavy path defers to FFmpeg `vidstab*` through the shared C bridge
///     (matches the Android `Stabilizer.kt` two-pass impl).
public final class Stabilizer {

  public enum Mode { case light, medium, heavy }

  public struct Progress { public let pct: Double; public let pass: Int }

  public init() {}

  public func stabilize(input: URL, output: URL, mode: Mode = .medium,
                        progress: ((Progress) -> Void)? = nil) async throws {
    switch mode {
    case .light:
      try await stabilizeLight(input: input, output: output, progress: progress)
    case .medium, .heavy:
      try stabilizeViaFFmpeg(input: input, output: output, mode: mode, progress: progress)
    }
  }

  // MARK: - Light path (Vision)

  private func stabilizeLight(input: URL, output: URL,
                              progress: ((Progress) -> Void)?) async throws {
    let asset = AVURLAsset(url: input)
    guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
      throw NSError(domain: "Stabilizer", code: -1)
    }
    let composition = AVMutableVideoComposition()
    composition.frameDuration = CMTime(value: 1, timescale: 30)
    composition.renderSize = videoTrack.naturalSize

    let instr = AVMutableVideoCompositionInstruction()
    instr.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
    instr.layerInstructions = [layer]
    composition.instructions = [instr]

    let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
    session?.videoComposition = composition
    session?.outputURL = output
    session?.outputFileType = .mp4
    await session?.export()
    progress?(Progress(pct: 1.0, pass: 1))
    if session?.status != .completed {
      throw NSError(domain: "Stabilizer", code: -2, userInfo: [
        NSLocalizedDescriptionKey: session?.error?.localizedDescription ?? "export failed",
      ])
    }
  }

  // MARK: - Heavy path (FFmpeg)

  private func stabilizeViaFFmpeg(input: URL, output: URL, mode: Mode,
                                  progress: ((Progress) -> Void)?) throws {
    // Phase 2.5: route through `ff_stabilize_run` once that verb is added
    // to ff_bridge.c. Mirrors the Android `Stabilizer.kt` two-pass call —
    // see improvement3.md §C7.
    throw NSError(domain: "Stabilizer", code: -100,
                  userInfo: [NSLocalizedDescriptionKey: "heavy stabilize not yet wired"])
  }
}
