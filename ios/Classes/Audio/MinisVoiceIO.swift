import AVFoundation
import Foundation

/// Switches `AVAudioSession` to `.voiceChat` mode, which engages the iOS built-in
/// echo cancellation / noise suppression / AGC pipeline (same DSP as
/// `kAudioUnitSubType_VoiceProcessingIO`). On `disable()` restores the prior config.
final class MinisVoiceIO {

    private var savedCategory: AVAudioSession.Category?
    private var savedMode: AVAudioSession.Mode?
    private var savedOptions: AVAudioSession.CategoryOptions = []
    private var active: Bool = false

    static func isAvailable() -> Bool {
        // `.voiceChat` mode exists on every supported iOS version.
        return true
    }

    func enableForMonitoring() throws {
        let session = AVAudioSession.sharedInstance()
        if !active {
            savedCategory = session.category
            savedMode = session.mode
            savedOptions = session.categoryOptions
        }
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: [])
        active = true
    }

    func disable() throws {
        guard active else { return }
        let session = AVAudioSession.sharedInstance()
        let cat = savedCategory ?? .ambient
        let mode = savedMode ?? .default
        let opts = savedOptions
        do {
            try session.setCategory(cat, mode: mode, options: opts)
        } catch {
            // Fall back to ambient/default if restore fails.
            try? session.setCategory(.ambient, mode: .default, options: [])
        }
        active = false
        savedCategory = nil
        savedMode = nil
        savedOptions = []
    }
}
