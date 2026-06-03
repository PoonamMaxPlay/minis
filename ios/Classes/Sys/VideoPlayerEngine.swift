import Flutter
import Foundation
import AVFoundation

final class VideoPlayerEngine: NSObject {
  static let methodChannelName = "loopit/minis/player"
  static let eventChannelPrefix = "loopit/minis/player/events/"

  private let messenger: FlutterBinaryMessenger
  private let methodChannel: FlutterMethodChannel
  private var sessions: [String: Session] = [:]

  final class Session {
    let player: AVPlayer
    let item: AVPlayerItem
    let eventChannel: FlutterEventChannel
    var eventSink: FlutterEventSink?
    var durationMs: Int = 0
    var width: Int = 0
    var height: Int = 0
    var statusObs: NSKeyValueObservation?
    var rateObs: NSKeyValueObservation?
    var endObs: NSObjectProtocol?
    var loop: Bool = false
    weak var layer: AVPlayerLayer?
    init(player: AVPlayer, item: AVPlayerItem, eventChannel: FlutterEventChannel) {
      self.player = player; self.item = item; self.eventChannel = eventChannel
    }
  }

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    self.methodChannel = FlutterMethodChannel(name: VideoPlayerEngine.methodChannelName, binaryMessenger: messenger)
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  func dispose() {
    let ids = Array(sessions.keys)
    ids.forEach { dispose(playerId: $0) }
    methodChannel.setMethodCallHandler(nil)
  }

  func session(for id: String) -> Session? { sessions[id] }
  func attach(layer: AVPlayerLayer, to playerId: String) {
    guard let s = sessions[playerId] else { return }
    layer.player = s.player
    s.layer = layer
  }
  func detach(playerId: String) { sessions[playerId]?.layer?.player = nil }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = (call.arguments as? [String: Any]) ?? [:]
    switch call.method {
    case "create": create(args, result: result)
    case "play":
      if let id = args["playerId"] as? String, let s = sessions[id] { s.player.play() }
      result(nil)
    case "pause":
      if let id = args["playerId"] as? String, let s = sessions[id] { s.player.pause() }
      result(nil)
    case "seek":
      if let id = args["playerId"] as? String, let s = sessions[id] {
        let ms = (args["ms"] as? NSNumber)?.intValue ?? 0
        let t = CMTime(value: Int64(ms), timescale: 1000)
        s.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
      }
      result(nil)
    case "volume":
      if let id = args["playerId"] as? String, let s = sessions[id] {
        let v = (args["value"] as? NSNumber)?.floatValue ?? 1.0
        s.player.volume = max(0, min(1, v))
      }
      result(nil)
    case "rate":
      if let id = args["playerId"] as? String, let s = sessions[id] {
        let r = (args["value"] as? NSNumber)?.floatValue ?? 1.0
        s.player.rate = r
      }
      result(nil)
    case "dispose":
      if let id = args["playerId"] as? String { dispose(playerId: id) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func create(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String else {
      result(FlutterError(code: "arg", message: "path required", details: nil)); return
    }
    let loop = (args["loop"] as? Bool) ?? false
    let autoplay = (args["autoplay"] as? Bool) ?? false
    let mute = (args["mute"] as? Bool) ?? false
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    if mute { player.volume = 0 }
    let playerId = UUID().uuidString
    let eventChannel = FlutterEventChannel(name: VideoPlayerEngine.eventChannelPrefix + playerId, binaryMessenger: messenger)
    let session = Session(player: player, item: item, eventChannel: eventChannel)
    session.loop = loop

    let durSec = CMTimeGetSeconds(asset.duration)
    if durSec.isFinite { session.durationMs = Int(durSec * 1000) }
    if let track = asset.tracks(withMediaType: .video).first {
      let sz = track.naturalSize.applying(track.preferredTransform)
      session.width = Int(abs(sz.width)); session.height = Int(abs(sz.height))
    }

    eventChannel.setStreamHandler(Streamer(onListen: { sink in session.eventSink = sink },
                                           onCancel: { session.eventSink = nil }))
    session.statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard let self = self else { return }
      switch item.status {
      case .readyToPlay:
        let d = CMTimeGetSeconds(item.duration)
        if d.isFinite { session.durationMs = Int(d * 1000) }
        self.emit(session, kind: "ready")
      case .failed: session.eventSink?(["kind": "error", "err": item.error?.localizedDescription ?? "failed"])
      default: break
      }
    }
    session.rateObs = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
      guard let self = self else { return }
      self.emit(session, kind: p.rate > 0 ? "playing" : "paused")
    }
    session.endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      if session.loop {
        session.player.seek(to: .zero); session.player.play()
      } else {
        self.emit(session, kind: "completed")
      }
    }

    sessions[playerId] = session
    if autoplay { player.play() }
    result(["playerId": playerId, "durationMs": session.durationMs, "w": session.width, "h": session.height])
  }

  private func emit(_ s: Session, kind: String) {
    let posMs = Int(CMTimeGetSeconds(s.player.currentTime()) * 1000)
    var bufMs = 0
    if let r = s.item.loadedTimeRanges.last as? CMTimeRange? ?? nil {
      bufMs = Int(CMTimeGetSeconds(CMTimeRangeGetEnd(r)) * 1000)
    }
    s.eventSink?(["kind": kind, "posMs": posMs, "bufMs": bufMs])
  }

  func dispose(playerId: String) {
    guard let s = sessions.removeValue(forKey: playerId) else { return }
    s.statusObs?.invalidate(); s.rateObs?.invalidate()
    if let e = s.endObs { NotificationCenter.default.removeObserver(e) }
    s.layer?.player = nil
    s.player.pause()
    s.eventChannel.setStreamHandler(nil)
  }

  private final class Streamer: NSObject, FlutterStreamHandler {
    let onListenCb: (FlutterEventSink) -> Void
    let onCancelCb: () -> Void
    init(onListen: @escaping (FlutterEventSink) -> Void, onCancel: @escaping () -> Void) {
      self.onListenCb = onListen; self.onCancelCb = onCancel
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { onListenCb(events); return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { onCancelCb(); return nil }
  }
}
