import AVFoundation
import Flutter
import Foundation

/// Posts route-change + interruption events to the audio state EventChannel.
/// Survives BT A2DP↔HFP↔built-in flips: AVAudioEngine handles the splice
/// internally; we just propagate the reason so Dart can show user feedback.
final class MinisAudioRouteWatcher {
    private var sink: FlutterEventSink?
    private var observers: [NSObjectProtocol] = []

    func attachSink(_ s: FlutterEventSink?) {
        sink = s
    }

    func start() {
        stop()
        let nc = NotificationCenter.default
        let route = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
        let interrupt = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        observers = [route, interrupt]
    }

    func stop() {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
        observers.removeAll()
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        let name: String
        switch reason {
        case .newDeviceAvailable: name = "newDeviceAvailable"
        case .oldDeviceUnavailable: name = "oldDeviceUnavailable"
        case .categoryChange: name = "categoryChange"
        case .override: name = "override"
        case .wakeFromSleep: name = "wakeFromSleep"
        case .noSuitableRouteForCategory: name = "noSuitableRoute"
        case .routeConfigurationChange: name = "routeConfig"
        case .unknown: name = "unknown"
        @unknown default: name = "unknown"
        }
        post(["type": "routeChange", "reason": name])
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let name = (type == .began) ? "began" : "ended"
        post(["type": "interruption", "phase": name])
    }

    private func post(_ payload: [String: Any]) {
        sink?(payload)
    }
}
