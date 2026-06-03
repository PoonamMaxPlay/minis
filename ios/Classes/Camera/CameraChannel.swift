import Flutter
import Foundation

/// Hosts the MethodChannel + 4 EventChannels on the iOS side and dispatches
/// to [MinisCameraEngine].
public final class MinisCameraChannel: NSObject {
    public let engine = MinisCameraEngine()

    private var methodChannel: FlutterMethodChannel?
    private var stateChannel: FlutterEventChannel?
    private var audioChannel: FlutterEventChannel?
    private var metaChannel: FlutterEventChannel?
    private var analysisChannel: FlutterEventChannel?

    private var stateHandler: MinisStreamHandler?
    private var audioHandler: MinisStreamHandler?
    private var metaHandler: MinisStreamHandler?
    private var analysisHandler: MinisStreamHandler?

    public func register(messenger: FlutterBinaryMessenger) {
        methodChannel = FlutterMethodChannel(name: "com.buzzit.social/minis_native_camera", binaryMessenger: messenger)
        methodChannel?.setMethodCallHandler { [weak self] in self?.onMethod(call: $0, result: $1) }

        let prefix = "com.buzzit.social/minis_native_camera"

        stateHandler = MinisStreamHandler { [weak self] sink in self?.engine.stateSink = sink }
        audioHandler = MinisStreamHandler { [weak self] sink in self?.engine.audioLevelSink = sink }
        metaHandler = MinisStreamHandler { [weak self] sink in self?.engine.metadataSink = sink }
        analysisHandler = MinisStreamHandler { [weak self] sink in self?.engine.analysisSink = sink }

        stateChannel = FlutterEventChannel(name: "\(prefix)/state", binaryMessenger: messenger)
        stateChannel?.setStreamHandler(stateHandler)
        audioChannel = FlutterEventChannel(name: "\(prefix)/audio_levels", binaryMessenger: messenger)
        audioChannel?.setStreamHandler(audioHandler)
        metaChannel = FlutterEventChannel(name: "\(prefix)/metadata", binaryMessenger: messenger)
        metaChannel?.setStreamHandler(metaHandler)
        analysisChannel = FlutterEventChannel(name: "\(prefix)/analysis", binaryMessenger: messenger)
        analysisChannel?.setStreamHandler(analysisHandler)
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private func onMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "warmUp", "init":
            engine.warmUp { err in
                if let e = err { result(FlutterError(code: "WARMUP_FAILED", message: e.localizedDescription, details: nil)) }
                else { result(nil) }
            }
        case "bind":
            let tier = (args["qualityTier"] as? Int) ?? 2
            let audio = (args["enableAudio"] as? Bool) ?? true
            engine.bind(qualityTier: tier, enableAudio: audio) { err in
                if let e = err { result(FlutterError(code: "BIND_FAILED", message: e.localizedDescription, details: nil)) }
                else { result(nil) }
            }
        case "setLens":
            engine.setLens(args["lensFacing"] as? String ?? "back") { err in
                if let e = err { result(FlutterError(code: "LENS_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "switchCamera":
            engine.switchCamera { err in
                if let e = err { result(FlutterError(code: "SWITCH_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "setFlash":
            engine.setFlash(args["mode"] as? String ?? "off") { err in
                if let e = err { result(FlutterError(code: "FLASH_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "setTorchEnabled":
            let on = call.arguments as? Bool ?? false
            engine.setTorch(on) { err in
                if let e = err { result(FlutterError(code: "TORCH_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "setZoom":
            let ratio = (args["ratio"] as? Double) ?? 1.0
            engine.setZoom(ratio) { err in
                if let e = err { result(FlutterError(code: "ZOOM_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "setZoomLevel":
            let ratio = (call.arguments as? Double) ?? 1.0
            engine.setZoom(ratio) { err in
                if let e = err { result(FlutterError(code: "ZOOM_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "getMinZoom": result(engine.zoomBounds().0)
        case "getMaxZoom": result(engine.zoomBounds().1)
        case "setExposure":
            engine.setExposureBias((args["ev"] as? Double) ?? 0) { err in
                if let e = err { result(FlutterError(code: "EV_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "setManual":
            engine.setManual(
                iso: args["iso"] as? Int,
                shutterNs: args["shutterNs"] as? Int64,
                wbKelvin: args["wbKelvin"] as? Int,
                lensPos: args["lensPos"] as? Double
            ) { err in
                if let e = err { result(FlutterError(code: "MANUAL_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "tapToFocus":
            engine.tapToFocus(x: (args["x"] as? Double) ?? 0.5, y: (args["y"] as? Double) ?? 0.5) { err in
                if let e = err { result(FlutterError(code: "FOCUS_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "setResolution":
            engine.setResolution(
                w: (args["w"] as? Int) ?? 1280,
                h: (args["h"] as? Int) ?? 720,
                fps: (args["fps"] as? Int) ?? 30
            ) { ok, err in
                if let e = err { result(FlutterError(code: "RES_FAILED", message: e.localizedDescription, details: nil)) }
                else { result(["accepted": ok]) }
            }
        case "enableHdr":
            engine.enableHDR((args["on"] as? Bool) ?? false) { enabled in result(["enabled": enabled]) }
        case "enableSlowMo":
            engine.enableSlowMo((args["fps"] as? Int) ?? 120) { enabled, actual in
                result(["enabled": enabled, "actualFps": actual])
            }
        case "enableTimeLapse":
            engine.enableTimeLapse(
                intervalMs: (args["intervalMs"] as? Int) ?? 1000,
                durationMs: (args["durationMs"] as? Int) ?? 60000
            ) { err in
                if let e = err { result(FlutterError(code: "TL_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "startMultiCam":
            engine.startMultiCam((args["layout"] as? String) ?? "topRight") { err in
                if let e = err { result(FlutterError(code: "MULTICAM_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "stopMultiCam":
            engine.stopMultiCam { path, err in
                if let e = err { result(FlutterError(code: "MULTICAM_STOP_FAILED", message: e.localizedDescription, details: nil)) }
                else { result(["path": path as Any]) }
            }
        case "takePhoto":
            engine.captureStill(raw: (args["raw"] as? Bool) ?? false, hdr: (args["hdr"] as? Bool) ?? false) { path, exif in
                result(["path": path as Any, "exif": exif])
            }
        case "takePicture":
            engine.captureStill(raw: false, hdr: false) { path, _ in result(path as Any) }
        case "startRecording":
            engine.startRecord(pathHint: call.arguments as? String) { err in
                if let e = err { result(FlutterError(code: "START_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "pauseRecord": engine.pauseRecord(); result(nil)
        case "resumeRecord": engine.resumeRecord(); result(nil)
        case "stopRecord":
            engine.stopRecord { url, dur, size, err in
                if let e = err { result(FlutterError(code: "STOP_FAILED", message: e.localizedDescription, details: nil)) }
                else { result(["path": url?.path as Any, "durationMs": dur, "size": size]) }
            }
        case "stopRecording":
            engine.stopRecord { url, _, _, err in
                if let e = err { result(FlutterError(code: "STOP_FAILED", message: e.localizedDescription, details: nil)) }
                else { result(url?.path) }
            }
        case "finalizeClips":
            let list = (args["clipPaths"] as? [String]) ?? []
            engine.finalizeClips(list) { url, err in
                if let e = err { result(FlutterError(code: "MERGE_FAILED", message: e.localizedDescription, details: nil)) }
                else { result(["mergedPath": url?.path as Any]) }
            }
        case "setMic":
            engine.setMic(deviceId: args["deviceId"] as? String, gain: args["gain"] as? Double) { err in
                if let e = err { result(FlutterError(code: "MIC_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "setRecordWithAudio":
            engine.setRecordWithAudio((call.arguments as? Bool) ?? true) { err in
                if let e = err { result(FlutterError(code: "MIC_FAILED", message: e.localizedDescription, details: nil)) } else { result(nil) }
            }
        case "getCapabilities":
            result(engine.capabilities())
        case "probeRecovery":
            let probe = engine.probeRecovery()
            if probe.paths.isEmpty { result(nil) }
            else { result(["segmentPaths": probe.paths, "totalDurationMs": probe.totalMs]) }
        case "recoverAndFinalize":
            engine.recoverAndFinalize(outPath: args["outPath"] as? String) { path, err in
                if let p = path { result(["mergedPath": p]) }
                else { result(FlutterError(code: "RECOVERY_FAILED", message: err?.localizedDescription, details: nil)) }
            }
        case "discardRecovery":
            engine.discardRecovery(); result(nil)
        case "listMics":
            result(["mics": engine.listMics()])
        case "dispose":
            engine.release(); result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}

private final class MinisStreamHandler: NSObject, FlutterStreamHandler {
    private let onListen: (FlutterEventSink?) -> Void
    init(onListen: @escaping (FlutterEventSink?) -> Void) { self.onListen = onListen }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListen(events); return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onListen(nil); return nil
    }
}
