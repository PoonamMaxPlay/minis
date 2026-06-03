import AVFoundation
import Flutter
import Foundation

/// N AVAudioPlayer instances keyed by id. Position polling via DispatchSource.
final class MinisPlayerRegistry: NSObject {
    private var slots: [Int: Slot] = [:]
    private var nextId: Int = 1
    private let queue = DispatchQueue(label: "minis.audio.players")
    private var sink: FlutterEventSink?

    func attachSink(_ s: FlutterEventSink?) {
        queue.sync { sink = s }
    }

    func createOrReplace(path: String, volume: Float, existingId: Int?) throws -> [String: Any] {
        if let eid = existingId { dispose(id: eid) }
        let url: URL
        if path.hasPrefix("file://"), let u = URL(string: path) {
            url = u
        } else {
            url = URL(fileURLWithPath: path)
        }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            throw error
        }
        player.enableRate = true
        player.volume = volume
        guard player.prepareToPlay() else {
            throw NSError(domain: "MinisAudio", code: -1, userInfo: [NSLocalizedDescriptionKey: "prepareToPlay failed"])
        }
        let id: Int = queue.sync {
            let assigned = nextId
            nextId += 1
            return assigned
        }
        let slot = Slot(id: id, player: player)
        player.delegate = slot
        slot.completionHandler = { [weak self] in
            self?.handleCompletion(id: id)
        }
        queue.sync { slots[id] = slot }
        let durMs = Int(player.duration * 1000.0)
        slot.durationMs = durMs
        return ["playerId": id, "durationMs": durMs]
    }

    func control(id: Int, op: String, value: Any?) {
        guard let slot = queue.sync(execute: { slots[id] }) else { return }
        let player = slot.player
        switch op {
        case "play":
            player.play()
            slot.playing = true
            emitState(slot, "playing")
            startPositionPump(slot)
        case "pause":
            player.pause()
            slot.playing = false
            emitState(slot, "paused")
        case "stop":
            player.stop()
            player.currentTime = 0
            slot.playing = false
            emitState(slot, "stopped")
        case "seek":
            let ms = (value as? NSNumber)?.intValue ?? 0
            player.currentTime = Double(ms) / 1000.0
            emit(["playerId": id, "type": "position", "positionMs": ms])
        case "volume":
            let v = (value as? NSNumber)?.floatValue ?? 1.0
            player.volume = v
        case "rate":
            let v = (value as? NSNumber)?.floatValue ?? 1.0
            player.rate = max(0.25, min(4.0, v))
        default:
            break
        }
    }

    func setFinishMode(id: Int, mode: String) {
        queue.sync { slots[id]?.finishMode = mode }
    }

    func duration(id: Int) -> Int {
        guard let slot = queue.sync(execute: { slots[id] }) else { return 0 }
        return Int(slot.player.duration * 1000.0)
    }

    func dispose(id: Int) {
        let slot: Slot? = queue.sync {
            let s = slots[id]
            slots.removeValue(forKey: id)
            return s
        }
        guard let s = slot else { return }
        s.player.stop()
        s.disposed = true
        s.timer?.cancel()
        s.timer = nil
    }

    private func handleCompletion(id: Int) {
        guard let slot = queue.sync(execute: { slots[id] }) else { return }
        slot.playing = false
        emit(["playerId": id, "type": "completed"])
        emitState(slot, "paused")
        switch slot.finishMode {
        case "loop":
            slot.player.currentTime = 0
            slot.player.play()
            slot.playing = true
            emitState(slot, "playing")
        case "stop":
            slot.player.stop()
            emitState(slot, "stopped")
        default: break
        }
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.sink?(event)
        }
    }

    private func emitState(_ slot: Slot, _ state: String) {
        emit(["playerId": slot.id, "type": "state", "state": state])
    }

    private func startPositionPump(_ slot: Slot) {
        slot.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(80), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self, weak slot] in
            guard let self = self, let slot = slot else { return }
            if slot.disposed || !slot.playing {
                slot.timer?.cancel()
                slot.timer = nil
                return
            }
            let ms = Int(slot.player.currentTime * 1000.0)
            self.emit(["playerId": slot.id, "type": "position", "positionMs": ms])
        }
        slot.timer = timer
        timer.resume()
    }

    final class Slot: NSObject, AVAudioPlayerDelegate {
        let id: Int
        let player: AVAudioPlayer
        var playing = false
        var disposed = false
        var finishMode: String = "pause"
        var durationMs: Int = 0
        var timer: DispatchSourceTimer?
        var completionHandler: (() -> Void)?

        init(id: Int, player: AVAudioPlayer) {
            self.id = id
            self.player = player
            super.init()
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            completionHandler?()
        }
    }
}
