import AVFoundation
import Foundation

/// `audio_session` parity on iOS: AVAudioSession category/mode/options + active.
final class MinisAudioSession {
    func configure(args: [String: Any]) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let category = mapCategory(args["category"] as? String)
        let mode = mapMode(args["mode"] as? String)
        let optionsRaw = (args["categoryOptions"] as? NSNumber)?.uintValue ?? 0
        let options = AVAudioSession.CategoryOptions(rawValue: optionsRaw)
        do {
            try session.setCategory(category, mode: mode, options: options)
            return true
        } catch {
            return false
        }
    }

    func setActive(_ active: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
            return active
        } catch {
            return false
        }
    }

    func listInputs() -> [[String: Any]] {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        return inputs.map { port in
            [
                "id": port.uid,
                "label": port.portName,
                "kind": kindName(port.portType),
            ]
        }
    }

    func setPreferredInput(id: String) -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard let port = (session.availableInputs ?? []).first(where: { $0.uid == id }) else {
            return false
        }
        do {
            try session.setPreferredInput(port)
            return true
        } catch {
            return false
        }
    }

    private func kindName(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInMic: return "builtin"
        case .headsetMic: return "wiredHeadset"
        case .bluetoothHFP: return "bluetoothSco"
        case .bluetoothA2DP: return "bluetoothA2dp"
        case .bluetoothLE: return "bluetoothLe"
        case .usbAudio: return "usbDevice"
        case .lineIn: return "lineIn"
        case .carAudio: return "carAudio"
        case .airPlay: return "airPlay"
        default: return "unknown"
        }
    }

    private func mapCategory(_ name: String?) -> AVAudioSession.Category {
        switch name {
        case "playback": return .playback
        case "record": return .record
        case "playAndRecord": return .playAndRecord
        case "multiRoute": return .multiRoute
        case "soloAmbient": return .soloAmbient
        default: return .ambient
        }
    }

    private func mapMode(_ name: String?) -> AVAudioSession.Mode {
        switch name {
        case "gameChat": return .gameChat
        case "measurement": return .measurement
        case "moviePlayback": return .moviePlayback
        case "spokenAudio": return .spokenAudio
        case "videoChat": return .videoChat
        case "videoRecording": return .videoRecording
        case "voiceChat": return .voiceChat
        default: return .default
        }
    }
}
