import Flutter
import Foundation
import AVFoundation

/// MethodChannel handler for `loopit/minis/videdit` on iOS. Mirrors the
/// Android `VideoEditEngine.kt` surface and forwards heavy work to the
/// shared FFmpeg C bridge in `Classes/VidEdit/c/ff_bridge.c`.
@objc public class VideoEditEngine: NSObject {

  static let channelMethod = "loopit/minis/videdit"
  static let channelProgress = "loopit/minis/videdit/progress"
  static let channelState = "loopit/minis/videdit/state"

  private let method: FlutterMethodChannel
  private let progress: FlutterEventChannel
  private let state: FlutterEventChannel
  private let progressSink = SinkHolder()
  private let stateSink = SinkHolder()
  private var activeTasks: Set<String> = []
  private let queue = DispatchQueue(label: "loopit.minis.videdit", qos: .userInitiated, attributes: .concurrent)

  @objc public init(messenger: FlutterBinaryMessenger) {
    method = FlutterMethodChannel(name: Self.channelMethod, binaryMessenger: messenger)
    progress = FlutterEventChannel(name: Self.channelProgress, binaryMessenger: messenger)
    state = FlutterEventChannel(name: Self.channelState, binaryMessenger: messenger)
    super.init()
    method.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    progress.setStreamHandler(StreamHandler(holder: progressSink))
    state.setStreamHandler(StreamHandler(holder: stateSink))
  }

  // ──────────────────────────────────────────────────────────────────
  // MethodChannel dispatch
  // ──────────────────────────────────────────────────────────────────

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      result([
        "viewId": "loopit/minis/videdit/preview",
        "ffmpegBuildInfo": Self.ffmpegBuildInfo(),
        "engineAvailable": true,
      ])
    case "getCapabilities":
      result(Self.capabilities())
    case "probe":
      onProbe(call: call, result: result)
    case "loadTimeline":
      onLoadTimeline(call: call, result: result)
    case "thumbnailStrip":
      onThumbStrip(call: call, result: result)
    case "thumbnailAt":
      onThumbAt(call: call, result: result)
    case "trim":
      onTrim(call: call, result: result)
    case "concat":
      onConcat(call: call, result: result)
    case "repair":
      onRepair(call: call, result: result)
    case "export":
      onExport(call: call, result: result)
    case "burnCaptions":
      onBurnCaptions(call: call, result: result)
    case "composeBackground":
      onComposeBackground(call: call, result: result)
    case "mixAudio":
      onMixAudio(call: call, result: result)
    case "replaceAudio":
      onReplaceAudio(call: call, result: result)
    case "cancelTask":
      onCancel(call: call, result: result)
    case "addClip", "removeClip", "splitClip", "setClipTransform", "setClipSpeed",
         "setClipFilter", "addTransition", "addText", "addSticker",
         "addAudioTrack", "setMasterVolumeEnv", "stabilize", "denoise",
         "autoCaption", "seek", "play", "pause":
      result(FlutterError(code: "unimplemented", message: "\(call.method) not yet wired", details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // Probe / load
  // ──────────────────────────────────────────────────────────────────

  private func onProbe(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String else {
      result(FlutterError(code: "args", message: "path missing", details: nil))
      return
    }
    queue.async {
      let info = Self.probe(path: path)
      DispatchQueue.main.async { result(info) }
    }
  }

  private func onLoadTimeline(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let timeline = args["timeline"] as? [String: Any],
      let clips = timeline["clips"] as? [[String: Any]],
      let first = clips.first?["path"] as? String
    else {
      result(["durationMs": 0])
      return
    }
    queue.async {
      let info = Self.probe(path: first)
      let ms = (info?["durationMs"] as? Int64) ?? 0
      DispatchQueue.main.async { result(["durationMs": ms]) }
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // Thumbnails
  // ──────────────────────────────────────────────────────────────────

  private func onThumbStrip(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String else {
      result(FlutterError(code: "args", message: "path", details: nil)); return
    }
    let count = (args["count"] as? Int) ?? 10
    let w = (args["w"] as? Int) ?? 160
    let h = (args["h"] as? Int) ?? 160
    queue.async {
      let thumbs = Thumbnailer.strip(path: path, count: count, width: w, height: h)
      DispatchQueue.main.async { result(["thumbs": thumbs]) }
    }
  }

  private func onThumbAt(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String else {
      result(FlutterError(code: "args", message: "path", details: nil)); return
    }
    let atMs = (args["atMs"] as? Int64) ?? 0
    let w = (args["w"] as? Int) ?? 240
    let h = (args["h"] as? Int) ?? 240
    queue.async {
      let bytes = Thumbnailer.single(path: path, atMs: atMs, width: w, height: h)
      DispatchQueue.main.async { result(["bytes": bytes as Any]) }
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // Trim / concat / repair / export — call into C bridge
  // ──────────────────────────────────────────────────────────────────

  private func onTrim(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let inPath = args["inputPath"] as? String,
          let outPath = args["outputPath"] as? String else {
      result(FlutterError(code: "args", message: "paths", details: nil)); return
    }
    let startMs = (args["startMs"] as? Int64) ?? 0
    let endMs = (args["endMs"] as? Int64) ?? 0
    let reencode = (args["reencode"] as? Bool) ?? true
    let taskId = UUID().uuidString
    activeTasks.insert(taskId)
    queue.async {
      var cb = makeProgressCb(taskId: taskId, sink: self.progressSink)
      let rc = ff_trim_run(inPath, outPath, startMs, endMs, reencode ? 1 : 0, &cb)
      DispatchQueue.main.async {
        self.activeTasks.remove(taskId)
        if rc == 0 { result(["outputPath": outPath, "taskId": taskId]) }
        else { result(FlutterError(code: "trim_failed", message: "rc=\(rc)", details: nil)) }
      }
    }
  }

  private func onConcat(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let paths = args["inputPaths"] as? [String],
          let out = args["outputPath"] as? String else {
      result(FlutterError(code: "args", message: "paths", details: nil)); return
    }
    let speed = (args["speed"] as? Double) ?? 1.0
    let keepAudio = (args["keepAudio"] as? Bool) ?? true
    let music = args["musicPath"] as? String
    let musicIn = (args["musicStartMs"] as? Int64) ?? 0
    let musicOut = (args["musicEndMs"] as? Int64) ?? 0
    let keepTempo = (args["keepMusicTempo"] as? Bool) ?? false
    let taskId = (args["taskId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
    activeTasks.insert(taskId)
    queue.async {
      var cb = makeProgressCb(taskId: taskId, sink: self.progressSink)
      let rc = paths.withCStringArray { ptrs in
        if let music = music {
          return ff_concat_run(ptrs, Int32(paths.count), out, speed, keepAudio ? 1 : 0,
                               music, musicIn, musicOut, keepTempo ? 1 : 0, &cb)
        } else {
          return ff_concat_run(ptrs, Int32(paths.count), out, speed, keepAudio ? 1 : 0,
                               nil, musicIn, musicOut, keepTempo ? 1 : 0, &cb)
        }
      }
      DispatchQueue.main.async {
        self.activeTasks.remove(taskId)
        if rc == 0 { result(["outputPath": out, "taskId": taskId]) }
        else { result(FlutterError(code: "concat_failed", message: "rc=\(rc)", details: nil)) }
      }
    }
  }

  private func onRepair(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let inPath = args["inputPath"] as? String,
          let outPath = args["outputPath"] as? String else {
      result(FlutterError(code: "args", message: "paths", details: nil)); return
    }
    let targetH = (args["targetHeight"] as? Int) ?? 720
    let taskId = UUID().uuidString
    activeTasks.insert(taskId)
    queue.async {
      var cb = makeProgressCb(taskId: taskId, sink: self.progressSink)
      let rc = ff_repair_run(inPath, outPath, Int32(targetH), &cb)
      DispatchQueue.main.async {
        self.activeTasks.remove(taskId)
        if rc == 0 { result(["outputPath": outPath]) }
        else { result(["outputPath": nil]) }
      }
    }
  }

  private func onExport(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let out = args["outPath"] as? String else {
      result(FlutterError(code: "args", message: "outPath", details: nil)); return
    }
    let preset = (args["preset"] as? String) ?? "feed"
    let options = (args["options"] as? [String: Any]) ?? [:]
    let optionsJson = (try? JSONSerialization.data(withJSONObject: options))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let taskId = UUID().uuidString
    activeTasks.insert(taskId)
    queue.async {
      var cb = makeProgressCb(taskId: taskId, sink: self.progressSink)
      let rc = ff_export_run("{}", preset, out, optionsJson, &cb)
      DispatchQueue.main.async {
        self.activeTasks.remove(taskId)
        if rc == 0 { result(["taskId": taskId, "outputPath": out]) }
        else { result(FlutterError(code: "export_failed", message: "rc=\(rc)", details: nil)) }
      }
    }
  }

  private func onBurnCaptions(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let inPath = args["inputPath"] as? String,
          let outPath = args["outputPath"] as? String,
          let srt = args["srtPath"] as? String else {
      result(FlutterError(code: "args", message: "paths", details: nil)); return
    }
    let style = (args["style"] as? String) ?? ""
    let taskId = UUID().uuidString
    activeTasks.insert(taskId)
    queue.async {
      var cb = makeProgressCb(taskId: taskId, sink: self.progressSink)
      let rc = ff_subtitles_burn(inPath, outPath, srt, style, &cb)
      DispatchQueue.main.async {
        self.activeTasks.remove(taskId)
        if rc == 0 { result(["outputPath": outPath, "taskId": taskId]) }
        else { result(FlutterError(code: "captions_failed", message: "rc=\(rc)", details: nil)) }
      }
    }
  }

  private func onComposeBackground(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let inPath = args["inputPath"] as? String,
          let atlas = args["maskAtlasPath"] as? String,
          let outPath = args["outputPath"] as? String else {
      result(FlutterError(code: "args", message: "paths", details: nil)); return
    }
    let bgSpec = (args["bgSpec"] as? String) ?? "#000000"
    let taskId = UUID().uuidString
    activeTasks.insert(taskId)
    queue.async {
      var cb = makeProgressCb(taskId: taskId, sink: self.progressSink)
      let rc = ff_bg_compose_run(inPath, atlas, bgSpec, outPath, &cb)
      DispatchQueue.main.async {
        self.activeTasks.remove(taskId)
        if rc == 0 { result(["outputPath": outPath, "taskId": taskId]) }
        else { result(FlutterError(code: "bgcompose_failed", message: "rc=\(rc)", details: nil)) }
      }
    }
  }

  private func onMixAudio(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let inputs = args["audioInputs"] as? [String],
          let filter = args["filter"] as? String,
          let out = args["outputPath"] as? String else {
      result(FlutterError(code: "args", message: "fields", details: nil)); return
    }
    let taskId = UUID().uuidString
    activeTasks.insert(taskId)
    queue.async {
      var cb = makeProgressCb(taskId: taskId, sink: self.progressSink)
      let rc = inputs.withCStringArray { ptrs in
        ff_audio_mix_run(ptrs, Int32(inputs.count), filter, out, &cb)
      }
      DispatchQueue.main.async {
        self.activeTasks.remove(taskId)
        if rc == 0 { result(["outputPath": out, "taskId": taskId]) }
        else { result(FlutterError(code: "mix_failed", message: "rc=\(rc)", details: nil)) }
      }
    }
  }

  private func onReplaceAudio(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let v = args["videoPath"] as? String,
          let a = args["audioPath"] as? String,
          let out = args["outputPath"] as? String else {
      result(FlutterError(code: "args", message: "paths", details: nil)); return
    }
    let taskId = UUID().uuidString
    activeTasks.insert(taskId)
    queue.async {
      var cb = makeProgressCb(taskId: taskId, sink: self.progressSink)
      let rc = ff_av_remux_run(v, a, out, &cb)
      DispatchQueue.main.async {
        self.activeTasks.remove(taskId)
        if rc == 0 { result(["outputPath": out, "taskId": taskId]) }
        else { result(FlutterError(code: "remux_failed", message: "rc=\(rc)", details: nil)) }
      }
    }
  }

  private func onCancel(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let taskId = args["taskId"] as? String else {
      result(FlutterError(code: "args", message: "taskId", details: nil)); return
    }
    activeTasks.remove(taskId)
    _ = ff_export_cancel(taskId)
    result(nil)
  }

  // ──────────────────────────────────────────────────────────────────
  // Capability + probe helpers
  // ──────────────────────────────────────────────────────────────────

  private static func capabilities() -> [String: Any] {
    var caps = ff_capabilities()
    ff_capabilities_query(&caps)
    return [
      "engineAvailable": true,
      "ffmpegBuildInfo": ffmpegBuildInfo(),
      "hwEnc": [
        "h264": true,
        "hevc": true,
      ],
      "hwDec": [
        "h264": true,
        "hevc": true,
        "vp9":  caps.hw_dec_vp9 != 0,
      ],
      "codecs": ["h264", "hevc", "prores", "aac", "opus"],
      "maxResolution": ["width": 3840, "height": 2160],
    ]
  }

  private static func ffmpegBuildInfo() -> String {
    return String(cString: ff_build_info())
  }

  private static func probe(path: String) -> [String: Any]? {
    guard let s = ff_session_open(path) else { return nil }
    var info = ff_session_info()
    let rc = ff_session_info_get(s, &info)
    ff_session_close(s)
    guard rc == 0 else { return nil }
    return [
      "durationMs": info.duration_ms,
      "width": Int(info.width),
      "height": Int(info.height),
      "fps": info.fps,
      "rotation": Int(info.rotation),
      "bitrate": info.bitrate,
      "videoCodec": String(cStringSafe: info.video_codec),
      "audioCodec": String(cStringSafe: info.audio_codec),
      "hasAudio": info.has_audio != 0,
      "audioSampleRate": Int(info.audio_sample_rate),
      "audioChannels": Int(info.audio_channels),
    ]
  }
}

// MARK: - Stream/sink plumbing

final class SinkHolder { var sink: FlutterEventSink? }

final class StreamHandler: NSObject, FlutterStreamHandler {
  private let holder: SinkHolder
  init(holder: SinkHolder) { self.holder = holder }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    holder.sink = events; return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    holder.sink = nil; return nil
  }
}

// MARK: - C callback bridging

private final class SinkBox {
  let sink: SinkHolder
  let taskId: String
  init(sink: SinkHolder, taskId: String) {
    self.sink = sink
    self.taskId = taskId
  }
}

private func progressEmit(user: UnsafeMutableRawPointer?,
                          taskId: UnsafePointer<CChar>?,
                          kind: UnsafePointer<CChar>?,
                          pct: Double, fps: Double, etaS: Double) {
  guard let user = user else { return }
  let box = Unmanaged<SinkBox>.fromOpaque(user).takeUnretainedValue()
  let payload: [String: Any] = [
    "taskId": String(cString: taskId ?? box.taskId),
    "kind": String(cString: kind ?? ""),
    "pct": pct,
    "fps": fps,
    "etaS": etaS,
  ]
  DispatchQueue.main.async {
    box.sink.sink?(payload)
  }
}

private func makeProgressCb(taskId: String, sink: SinkHolder) -> ff_progress_cb_t {
  var cb = ff_progress_cb_t()
  let box = SinkBox(sink: sink, taskId: taskId)
  cb.user = UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque())
  cb.emit = progressEmit
  cb.cancel_flag = 0
  return cb
}

// MARK: - Helpers

private extension String {
  init(cStringSafe tuple: Any) {
    // FFmpeg returns fixed-size char arrays as tuples in Swift. Map to a
    // contiguous buffer then String.init(cString:).
    let mirror = Mirror(reflecting: tuple)
    var bytes = mirror.children.compactMap { $0.value as? CChar }
    if !bytes.contains(0) { bytes.append(0) }
    self = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }
}

private extension Array where Element == String {
  func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    var cs: [UnsafePointer<CChar>?] = self.map { strdup($0) }.map { UnsafePointer($0) }
    defer { for p in cs { if let p = p { free(UnsafeMutableRawPointer(mutating: p)) } } }
    return cs.withUnsafeBufferPointer { buf in
      body(buf.baseAddress!)
    }
  }
}
