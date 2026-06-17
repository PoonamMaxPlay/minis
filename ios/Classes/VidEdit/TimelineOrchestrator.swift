import AVFoundation
import CoreMedia
import Foundation
import Metal

/// iOS counterpart of `TimelineOrchestrator.kt`. Walks a
/// [VidEditTimelineModel] against a wall clock, activates the right
/// clip(s), drives `AVAssetReader`s to fetch the matching frames, and
/// updates the `MetalCompositor` instruction so the next render tick
/// composites them.
public final class TimelineOrchestrator {

  private let composer: MetalCompositor?
  private var timeline: VidEditTimelineModel?
  private var positionMs: Int64 = 0
  private var playing = false
  private var displayLink: CADisplayLink?
  private var startMs: Int64 = 0
  private var basePosMs: Int64 = 0
  private var primaryReader: AVAssetReader?
  private var primaryOutput: AVAssetReaderTrackOutput?
  private var activePrimaryId: String?
  private var activeSecondaryId: String?

  public init(composer: MetalCompositor? = nil) {
    self.composer = composer
  }

  public func load(_ tl: VidEditTimelineModel) {
    timeline = tl
    positionMs = 0
    activePrimaryId = nil
    activeSecondaryId = nil
  }

  public func play() {
    guard timeline != nil, !playing else { return }
    playing = true
    startMs = Int64(Date().timeIntervalSince1970 * 1000)
    basePosMs = positionMs
    let dl = CADisplayLink(target: self, selector: #selector(onTick))
    dl.preferredFramesPerSecond = 60
    dl.add(to: .main, forMode: .common)
    displayLink = dl
  }

  public func pause() {
    playing = false
    displayLink?.invalidate()
    displayLink = nil
  }

  public func seek(ms: Int64) {
    positionMs = ms
    if playing {
      startMs = Int64(Date().timeIntervalSince1970 * 1000)
      basePosMs = ms
    }
  }

  public func release() {
    pause()
    primaryReader?.cancelReading()
    primaryReader = nil
    primaryOutput = nil
  }

  @objc private func onTick() {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    positionMs = nowMs - startMs + basePosMs
    activateClipsForPosition(positionMs)
  }

  private func activateClipsForPosition(_ posMs: Int64) {
    guard let tl = timeline else { return }
    let (primary, secondary, progress) = findActive(tl: tl, posMs: posMs)
    if primary?.id != activePrimaryId {
      if let p = primary { activatePrimary(clip: p, posMs: posMs) }
      activePrimaryId = primary?.id
    }
    if secondary?.id != activeSecondaryId {
      activeSecondaryId = secondary?.id
    }
    // The compositor reads progress / transition name off the next
    // `Instruction`. Phase 4.x exposes a helper on MetalCompositor that
    // mutates the active Instruction without rebuilding the whole
    // composition.
    _ = progress
  }

  private func activatePrimary(clip: VidEditClip, posMs: Int64) {
    primaryReader?.cancelReading()
    let url = URL(fileURLWithPath: clip.path)
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { return }
    do {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          (kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_32BGRA,
        ])
      output.alwaysCopiesSampleData = false
      reader.add(output)
      let startSec = Double(posMs - clip.positionMs + clip.inMs) / 1000.0
      reader.timeRange = CMTimeRange(
        start: CMTime(seconds: startSec, preferredTimescale: 600),
        duration: CMTime(seconds: Double(clip.outMs - clip.inMs) / 1000.0,
                         preferredTimescale: 600))
      reader.startReading()
      primaryReader = reader
      primaryOutput = output
    } catch {
      // Codec unsupported / IO error — leave the previous frame on screen.
    }
  }

  private func findActive(tl: VidEditTimelineModel, posMs: Int64)
      -> (VidEditClip?, VidEditClip?, Float) {
    guard let primary = tl.clips.first(where: { clip in
      let dur = clip.outMs - clip.inMs
      return posMs >= clip.positionMs && posMs < (clip.positionMs + dur)
    }) else {
      return (nil, nil, 0)
    }
    let transition = tl.transitions.first(where: { $0.aId == primary.id })
    let secondary = transition.flatMap { t in tl.clips.first(where: { $0.id == t.bId }) }
    if let t = transition, let _ = secondary {
      let primaryEnd = primary.positionMs + (primary.outMs - primary.inMs)
      let tStart = primaryEnd - t.durMs
      if posMs >= tStart && posMs <= primaryEnd {
        let p = Float(max(0, posMs - tStart)) / Float(max(1, t.durMs))
        return (primary, secondary, min(max(p, 0), 1))
      }
    }
    return (primary, nil, 0)
  }
}
