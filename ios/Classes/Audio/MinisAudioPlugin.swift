import AVFoundation
import Flutter
import Foundation

/// Hosts the `loopit/minis/audio` channels and dispatches into the session /
/// player / recorder / waveform extractor singletons.
public final class MinisAudioPlugin: NSObject {
    private let session = MinisAudioSession()
    private let players = MinisPlayerRegistry()
    private let recorder = MinisRecorder()
    private let waveform = MinisWaveformExtractor()
    private let routes = MinisAudioRouteWatcher()
    private let trimmer = MinisAudioTrimmer()
    private let mixer = MinisAudioMixer()
    private let normalizer = MinisLufsNormalizer()
    private let beats = MinisBeatDetector()
    private let pitcher = MinisPitchTimeStretch()

    private let methodChannel: FlutterMethodChannel
    private let playerEventsChannel: FlutterEventChannel
    private let levelsChannel: FlutterEventChannel
    private let stateChannel: FlutterEventChannel
    private let progressChannel: FlutterEventChannel

    private let playerEventsHandler = MinisStreamHandler()
    private let levelsHandler = MinisStreamHandler()
    private let stateHandler = MinisStreamHandler()
    private let progressHandler = MinisStreamHandler()
    private var progressSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = MinisAudioPlugin(messenger: registrar.messenger())
        registrar.publish(plugin)
    }

    init(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(
            name: "loopit/minis/audio",
            binaryMessenger: messenger
        )
        playerEventsChannel = FlutterEventChannel(
            name: "loopit/minis/audio/playerEvents",
            binaryMessenger: messenger
        )
        levelsChannel = FlutterEventChannel(
            name: "loopit/minis/audio/levels",
            binaryMessenger: messenger
        )
        stateChannel = FlutterEventChannel(
            name: "loopit/minis/audio/state",
            binaryMessenger: messenger
        )
        progressChannel = FlutterEventChannel(
            name: "loopit/minis/audio/progress",
            binaryMessenger: messenger
        )
        super.init()
        playerEventsHandler.onSinkChanged = { [weak self] sink in
            self?.players.attachSink(sink)
        }
        levelsHandler.onSinkChanged = { [weak self] sink in
            self?.recorder.attachLevelSink(sink)
        }
        stateHandler.onSinkChanged = { [weak self] sink in
            guard let self = self else { return }
            if sink != nil {
                self.routes.attachSink(sink)
                self.routes.start()
            } else {
                self.routes.stop()
                self.routes.attachSink(nil)
            }
        }
        progressHandler.onSinkChanged = { [weak self] sink in
            self?.progressSink = sink
        }
        playerEventsChannel.setStreamHandler(playerEventsHandler)
        levelsChannel.setStreamHandler(levelsHandler)
        stateChannel.setStreamHandler(stateHandler)
        progressChannel.setStreamHandler(progressHandler)
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "configureSession":
            let accepted = session.configure(args: args)
            result(["accepted": accepted])
        case "setSessionActive":
            let active = args["active"] as? Bool ?? false
            let applied = session.setActive(active)
            result(["active": applied])
        case "playerCreate":
            guard let path = args["path"] as? String else {
                result(FlutterError(code: "ARG", message: "path required", details: nil))
                return
            }
            let volume = (args["volume"] as? NSNumber)?.floatValue ?? 1.0
            let existingId = (args["existingId"] as? NSNumber)?.intValue
            do {
                let out = try players.createOrReplace(
                    path: path, volume: volume, existingId: existingId
                )
                result(out)
            } catch {
                result(FlutterError(code: "MINIS_AUDIO", message: error.localizedDescription, details: nil))
            }
        case "playerControl":
            guard let id = (args["playerId"] as? NSNumber)?.intValue,
                  let op = args["op"] as? String else {
                result(FlutterError(code: "ARG", message: "playerId+op required", details: nil)); return
            }
            players.control(id: id, op: op, value: args["value"])
            result(nil)
        case "playerSetFinishMode":
            guard let id = (args["playerId"] as? NSNumber)?.intValue else {
                result(FlutterError(code: "ARG", message: "playerId required", details: nil)); return
            }
            players.setFinishMode(id: id, mode: args["mode"] as? String ?? "pause")
            result(nil)
        case "playerGetDuration":
            guard let id = (args["playerId"] as? NSNumber)?.intValue else {
                result(FlutterError(code: "ARG", message: "playerId required", details: nil)); return
            }
            result(["durationMs": players.duration(id: id)])
        case "playerDispose":
            if let id = (args["playerId"] as? NSNumber)?.intValue {
                players.dispose(id: id)
            }
            result(nil)
        case "startRecord":
            guard let path = args["path"] as? String else {
                result(FlutterError(code: "ARG", message: "path required", details: nil)); return
            }
            do {
                try recorder.start(
                    path: path,
                    format: args["format"] as? String ?? "aac",
                    sampleRate: (args["sampleRate"] as? NSNumber)?.intValue ?? 44100,
                    channels: (args["channels"] as? NSNumber)?.intValue ?? 1,
                    bitRate: (args["bitRate"] as? NSNumber)?.intValue ?? 128000,
                    denoise: (args["denoise"] as? Bool) ?? false,
                    monitor: (args["monitor"] as? Bool) ?? false
                )
                result(nil)
            } catch {
                result(FlutterError(code: "MINIS_AUDIO", message: error.localizedDescription, details: nil))
            }
        case "pauseRecord":
            recorder.pause(); result(nil)
        case "resumeRecord":
            recorder.resume(); result(nil)
        case "stopRecord":
            result(recorder.stop())
        case "extractWaveform":
            guard let path = args["path"] as? String else {
                result(FlutterError(code: "ARG", message: "path required", details: nil)); return
            }
            let peaks = (args["peaks"] as? NSNumber)?.intValue ?? 1024
            waveform.extract(path: path, peakCount: peaks, result: result)
        // ---- improvement4.md deferred surface (D1.x/D6/D7/D8/D9) ----
        case "listInputs":
            result(["inputs": session.listInputs()])
        case "setInput":
            guard let id = args["id"] as? String else {
                result(FlutterError(code: "ARG", message: "id required", details: nil)); return
            }
            let ok = session.setPreferredInput(id: id)
            result(["applied": ok])
        case "trim":
            guard let path = args["path"] as? String,
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(code: "ARG", message: "path+outPath required", details: nil)); return
            }
            let inMs = (args["inMs"] as? NSNumber)?.intValue ?? 0
            let outMs = (args["outMs"] as? NSNumber)?.intValue ?? 0
            let mode = args["mode"] as? String ?? "accurate"
            trimmer.trim(path: path, inMs: inMs, outMs: outMs, outPath: outPath, mode: mode, result: result)
        case "mix":
            guard let raw = args["tracks"] as? [[String: Any]],
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(code: "ARG", message: "tracks+outPath required", details: nil)); return
            }
            var parsed: [MinisMixTrack] = []
            parsed.reserveCapacity(raw.count)
            for t in raw {
                guard let p = t["path"] as? String else { continue }
                let inMs = (t["inMs"] as? NSNumber)?.intValue ?? 0
                let outMs = (t["outMs"] as? NSNumber)?.intValue ?? inMs
                let posMs = (t["positionMs"] as? NSNumber)?.intValue ?? 0
                let env = parsePairs(t["gainEnv"])
                let pan = parsePairs(t["panEnv"])
                let eq = t["eq"] as? [String: Any]
                parsed.append(MinisMixTrack(
                    path: p, inMs: inMs, outMs: outMs, positionMs: posMs,
                    gainEnv: env, panEnv: pan,
                    eqLowDb: (eq?["lowDb"] as? NSNumber)?.doubleValue ?? 0,
                    eqMidDb: (eq?["midDb"] as? NSNumber)?.doubleValue ?? 0,
                    eqHighDb: (eq?["highDb"] as? NSNumber)?.doubleValue ?? 0,
                    fadeInMs: (t["fadeInMs"] as? NSNumber)?.doubleValue ?? 0,
                    fadeOutMs: (t["fadeOutMs"] as? NSNumber)?.doubleValue ?? 0,
                    fadeKind: (t["fadeKind"] as? String) ?? "linear",
                    isVoiceForDuck: (t["isVoice"] as? Bool) ?? false
                ))
            }
            let targetLufs = (args["targetLufs"] as? NSNumber)?.doubleValue ?? -14.0
            mixer.mix(tracks: parsed, outPath: outPath, targetLufs: targetLufs, result: result)
        case "normalize":
            guard let path = args["path"] as? String,
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(code: "ARG", message: "path+outPath required", details: nil)); return
            }
            let targetLufs = (args["targetLufs"] as? NSNumber)?.doubleValue ?? -14.0
            normalizer.normalize(path: path, outPath: outPath, targetLufs: targetLufs, result: result)
        case "detectBeats":
            guard let path = args["path"] as? String else {
                result(FlutterError(code: "ARG", message: "path required", details: nil)); return
            }
            beats.detect(path: path, result: result)
        case "pitchShift":
            guard let path = args["path"] as? String,
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(code: "ARG", message: "path+outPath required", details: nil)); return
            }
            let semitones = (args["semitones"] as? NSNumber)?.doubleValue ?? 0.0
            pitcher.pitchShift(path: path, semitones: semitones, outPath: outPath, result: result)
        case "timeStretch":
            guard let path = args["path"] as? String,
                  let outPath = args["outPath"] as? String else {
                result(FlutterError(code: "ARG", message: "path+outPath required", details: nil)); return
            }
            let factor = (args["factor"] as? NSNumber)?.doubleValue ?? 1.0
            let keepPitch = (args["keepPitch"] as? NSNumber)?.boolValue ?? true
            pitcher.timeStretch(
                path: path, factor: factor, keepPitch: keepPitch,
                outPath: outPath, result: result
            )
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func parsePairs(_ raw: Any?) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        if let arr = raw as? [[NSNumber]] {
            for pair in arr where pair.count >= 2 {
                out.append((pair[0].doubleValue, pair[1].doubleValue))
            }
        } else if let arr = raw as? [[String: Any]] {
            for m in arr {
                if let t = (m["timeMs"] as? NSNumber)?.doubleValue,
                   let g = (m["gain"] ?? m["pan"]) as? NSNumber {
                    out.append((t, g.doubleValue))
                }
            }
        }
        return out
    }

    private func notImpl(_ result: @escaping FlutterResult, _ method: String, _ anchor: String) {
        result(FlutterError(
            code: "NOT_IMPLEMENTED",
            message: "\(method) deferred (see improvement4.md \(anchor))",
            details: nil
        ))
    }
}

final class MinisStreamHandler: NSObject, FlutterStreamHandler {
    var onSinkChanged: ((FlutterEventSink?) -> Void)?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onSinkChanged?(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onSinkChanged?(nil)
        return nil
    }
}
