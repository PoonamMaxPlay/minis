import AVFoundation
import Foundation

/// Mirror of `android/.../videdit/Timeline.kt`. The MetalCompositor consumes
/// this model directly; the export pipeline serialises it to JSON before
/// handing it to the shared FFmpeg C bridge.
public struct VidEditTransform: Codable {
  public var translateX: Double = 0
  public var translateY: Double = 0
  public var scale: Double = 1
  public var rotateDeg: Double = 0
  public var cornerRadius: Double = 0
  public var mirrorH: Bool = false
  public var mirrorV: Bool = false
  public static let identity = VidEditTransform()
}

public struct VidEditClip: Codable {
  public var id: String
  public var path: String
  public var trackIndex: Int
  public var inMs: Int64
  public var outMs: Int64
  public var positionMs: Int64
  public var transform: VidEditTransform = .identity
  public var speed: Double = 1.0
  public var keepPitch: Bool = true
  public var lutPath: String? = nil
  public var lutIntensity: Double = 1.0
  public var volume: Double = 1.0
}

public struct VidEditTransition: Codable {
  public var id: String
  public var aId: String
  public var bId: String
  public var type: String      // crossfade | dip | slide | push | zoom | glitch
  public var durMs: Int64
}

public struct VidEditOverlay: Codable {
  public var id: String
  public var kind: String      // text | sticker
  public var params: [String: String]
}

public struct VidEditTimelineModel: Codable {
  public var clips: [VidEditClip]
  public var transitions: [VidEditTransition]
  public var overlays: [VidEditOverlay]
  public var durationMs: Int64
}
