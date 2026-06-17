import AVFoundation
import Foundation
import Speech

/// On-device speech recognition. Mirrors the Android `AutoCaptioner.kt` —
/// the host extracts 16 kHz mono PCM via the shared FFmpeg bridge, then
/// `SFSpeechRecognizer` (with `requiresOnDeviceRecognition = true`) returns
/// `SFTranscriptionSegment` entries that we map into [Cue]s.
public final class AutoCaptioner {

  public struct Cue: Codable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
  }

  public init() {}

  public func caption(audioFile: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> [Cue] {
    let status = await withCheckedContinuation { cont in
      SFSpeechRecognizer.requestAuthorization { s in cont.resume(returning: s) }
    }
    guard status == .authorized else {
      throw NSError(domain: "AutoCaptioner", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "speech permission denied"])
    }
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw NSError(domain: "AutoCaptioner", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "recognizer unavailable for \(locale.identifier)"])
    }
    let req = SFSpeechURLRecognitionRequest(url: audioFile)
    req.requiresOnDeviceRecognition = true
    req.shouldReportPartialResults = false

    return try await withCheckedThrowingContinuation { cont in
      recognizer.recognitionTask(with: req) { result, err in
        if let err = err {
          cont.resume(throwing: err); return
        }
        guard let result = result, result.isFinal else { return }
        let cues: [Cue] = result.bestTranscription.segments.map { seg in
          let start = Int64(seg.timestamp * 1000)
          let end = Int64((seg.timestamp + seg.duration) * 1000)
          return Cue(startMs: start, endMs: end, text: seg.substring)
        }
        cont.resume(returning: cues)
      }
    }
  }

  public func toSRT(_ cues: [Cue]) -> String {
    var out = ""
    for (i, c) in cues.enumerated() {
      out += "\(i + 1)\n"
      out += "\(format(c.startMs)) --> \(format(c.endMs))\n"
      out += "\(c.text)\n\n"
    }
    return out
  }

  private func format(_ ms: Int64) -> String {
    let h = ms / 3_600_000
    let m = (ms / 60_000) % 60
    let s = (ms / 1000) % 60
    let mss = ms % 1000
    return String(format: "%02lld:%02lld:%02lld,%03lld", h, m, s, mss)
  }
}
