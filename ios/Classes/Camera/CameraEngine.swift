import AVFoundation
import Flutter
import Foundation
import UIKit

/// Minis iOS camera engine. Owns `AVCaptureSession`, video / photo / audio
/// outputs, the recorder, manual controls, HDR, slow-mo, raw, multi-cam, and
/// surfaces them via `MinisCameraChannel`.
public final class MinisCameraEngine: NSObject {

    // Public state.
    public let session = AVCaptureSession()
    public let sessionMachine = MinisCameraSessionMachine()
    public weak var primaryPreview: MinisCameraPlatformView?
    public weak var secondaryPreview: MinisCameraPlatformView?

    // Outputs.
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var movieOutput: AVCaptureMovieFileOutput?

    // Inputs / device.
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private(set) var currentDevice: AVCaptureDevice?
    private var currentPosition: AVCaptureDevice.Position = .back

    // Recorder.
    private var recorder: MinisMultiClipRecorder?
    private let recorderQueue = DispatchQueue(label: "minis.camera.recorder")
    private let captureQueue = DispatchQueue(label: "minis.camera.capture")
    private var withAudio: Bool = true
    private var hdrEnabled = false
    private var rawEnabled = false
    private var slowMoFps: Int = 0
    private var timeLapseCtrl: MinisTimeLapseController?
    private var metadataEmitter: MinisMetadataEmitter?
    private var faceAnalyzer: MinisFaceAnalyzer?

    // Watchdog.
    private var lastFrameAt: TimeInterval = Date().timeIntervalSince1970
    private var watchdogTimer: DispatchSourceTimer?

    // Channels.
    public weak var stateSink: FlutterEventSink?
    public weak var audioLevelSink: FlutterEventSink?
    public weak var metadataSink: FlutterEventSink?
    public weak var analysisSink: FlutterEventSink?

    // Photo capture completion store.
    private var pendingPhotoCallback: ((String?, [String: Any]) -> Void)?

    public override init() {
        super.init()
        sessionMachine.listener = self
        if #available(iOS 13.0, *) {
            session.usesApplicationAudioSession = true
        }
    }

    // MARK: - Capabilities

    public func capabilities() -> [String: Any] {
        let manual = currentDevice.map { MinisManualControls.ranges(of: $0) }
        let supportedSlow = currentDevice.map { MinisSlowMoController.supportedRates(on: $0) } ?? []
        let hdrOk = currentDevice.map { MinisHDRController.isSupported(on: $0) } ?? false
        let rawOk = MinisRawCapture.isSupported(on: photoOutput)
        let multiCamOk: Bool
        if #available(iOS 13.0, *) { multiCamOk = AVCaptureMultiCamSession.isMultiCamSupported }
        else { multiCamOk = false }
        return [
            "hdr10": hdrOk,
            "raw": rawOk,
            "slowMoFps": supportedSlow,
            "multiCam": multiCamOk,
            "manualIso": manual?.minIso != nil,
            "manualShutter": manual?.minShutterSeconds != nil,
            "manualWb": true,
            "manualFocus": true,
            "timeLapse": true,
            "minIso": manual?.minIso ?? NSNull(),
            "maxIso": manual?.maxIso ?? NSNull(),
            "minShutterNs": Int((manual?.minShutterSeconds ?? 0) * 1_000_000_000),
            "maxShutterNs": Int((manual?.maxShutterSeconds ?? 0) * 1_000_000_000),
            "minZoom": Double(currentDevice?.minAvailableVideoZoomFactor ?? 1),
            "maxZoom": Double(currentDevice?.maxAvailableVideoZoomFactor ?? 1),
        ]
    }

    // MARK: - Bind

    public func warmUp(_ completion: @escaping (Error?) -> Void) {
        // Pre-flight only: AVCaptureSession is built lazily in bind().
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minis_native_capture", isDirectory: true)
        let probe = MinisMultiClipRecorder.probeOrphans(workDir: dir)
        if !probe.paths.isEmpty {
            DispatchQueue.main.async {
                let payload = probe.paths.joined(separator: "|") + "::\(probe.totalMs)"
                self.emitState(state: "preview", code: "recoveryAvailable", message: payload)
            }
        }
        completion(nil)
    }

    public func probeRecovery() -> (paths: [String], totalMs: Int64) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minis_native_capture", isDirectory: true)
        return MinisMultiClipRecorder.probeOrphans(workDir: dir)
    }

    public func recoverAndFinalize(outPath: String?, completion: @escaping (String?, Error?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minis_native_capture", isDirectory: true)
        let probe = MinisMultiClipRecorder.probeOrphans(workDir: dir)
        if probe.paths.isEmpty {
            completion(nil, NSError(domain: "minis", code: -40, userInfo: [NSLocalizedDescriptionKey: "no recoverable segments"]))
            return
        }
        let rec = MinisMultiClipRecorder(workDir: dir)
        let outUrl = URL(fileURLWithPath: outPath ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("minis_recovered_\(Int(Date().timeIntervalSince1970)).mp4").path)
        rec.finalizeMerged(to: outUrl) { url, err in
            if let u = url { rec.discard(); completion(u.path, nil) }
            else { completion(nil, err) }
        }
    }

    public func discardRecovery() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minis_native_capture", isDirectory: true)
        MinisMultiClipRecorder(workDir: dir).discard()
    }

    public func bind(qualityTier: Int, enableAudio: Bool, completion: @escaping (Error?) -> Void) {
        withAudio = enableAudio
        captureQueue.async {
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            self.session.sessionPreset = self.preset(for: qualityTier)

            // Inputs.
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            guard let device = self.bestVideoDevice(position: self.currentPosition) else {
                DispatchQueue.main.async { completion(NSError(domain: "minis", code: -10, userInfo: [NSLocalizedDescriptionKey: "no device"])) }
                return
            }
            self.metadataEmitter?.detach()
            self.metadataEmitter = nil
            self.currentDevice = device
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input) }
                self.videoInput = input
            } catch {
                DispatchQueue.main.async { completion(error) }
                return
            }

            if enableAudio,
               let mic = AVCaptureDevice.default(for: .audio),
               let aIn = try? AVCaptureDeviceInput(device: mic) {
                if self.session.canAddInput(aIn) { self.session.addInput(aIn) }
                self.audioInput = aIn
            }

            // Outputs.
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.recorderQueue)
            if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }

            if enableAudio {
                self.audioOutput.setSampleBufferDelegate(self, queue: self.recorderQueue)
                if self.session.canAddOutput(self.audioOutput) { self.session.addOutput(self.audioOutput) }
            }

            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            if #available(iOS 13.0, *) { self.photoOutput.maxPhotoQualityPrioritization = .quality }

            // Recorder fresh state.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minis_native_capture", isDirectory: true)
            self.recorder = MinisMultiClipRecorder(workDir: dir)

            if !self.session.isRunning { self.session.startRunning() }

            self.attachPreviewLayer()
            self.startWatchdog()
            // Metadata KVO emitter.
            let me = MinisMetadataEmitter(device: device)
            me.attach { [weak self] payload in
                DispatchQueue.main.async { self?.metadataSink?(payload) }
            }
            self.metadataEmitter = me
            // Face analyzer.
            let fa = MinisFaceAnalyzer()
            fa.setSink { [weak self] faces in
                DispatchQueue.main.async { self?.analysisSink?(["faces": faces]) }
            }
            self.faceAnalyzer = fa
            self.sessionMachine.transition(to: .preview)
            DispatchQueue.main.async { completion(nil) }
        }
    }

    private func bestVideoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if #available(iOS 13.0, *) {
            return AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        } else {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        }
    }

    private func preset(for tier: Int) -> AVCaptureSession.Preset {
        switch tier {
        case 0: return .vga640x480
        case 1: return .hd1280x720
        case 2: return .hd1920x1080
        case 3: if #available(iOS 9.0, *) { return .hd4K3840x2160 } else { return .high }
        default: return .high
        }
    }

    private func attachPreviewLayer() {
        DispatchQueue.main.async {
            if let pv = self.primaryPreview { pv.attach(session: self.session) }
            if let sv = self.secondaryPreview { sv.attach(session: self.session) }
        }
    }

    // MARK: - Camera params

    public func setLens(_ facing: String, completion: @escaping (Error?) -> Void) {
        currentPosition = (facing == "front") ? .front : .back
        bind(qualityTier: 2, enableAudio: withAudio, completion: completion)
    }

    public func switchCamera(_ completion: @escaping (Error?) -> Void) {
        currentPosition = (currentPosition == .back) ? .front : .back
        bind(qualityTier: 2, enableAudio: withAudio, completion: completion)
    }

    public func setFlash(_ mode: String, completion: @escaping (Error?) -> Void) {
        guard let d = currentDevice else { completion(NSError(domain: "minis", code: -11)); return }
        do {
            switch mode {
            case "torch": try MinisManualControls.setTorch(device: d, on: true)
            case "off": try MinisManualControls.setTorch(device: d, on: false)
            default: break // on/auto handled on AVCapturePhotoSettings
            }
            completion(nil)
        } catch { completion(error) }
    }

    public func setTorch(_ on: Bool, completion: @escaping (Error?) -> Void) {
        guard let d = currentDevice else { completion(NSError(domain: "minis", code: -11)); return }
        do { try MinisManualControls.setTorch(device: d, on: on); completion(nil) } catch { completion(error) }
    }

    public func setZoom(_ ratio: Double, completion: @escaping (Error?) -> Void) {
        guard let d = currentDevice else { completion(NSError(domain: "minis", code: -11)); return }
        do {
            try d.lockForConfiguration()
            d.videoZoomFactor = max(d.minAvailableVideoZoomFactor, min(CGFloat(ratio), d.maxAvailableVideoZoomFactor))
            d.unlockForConfiguration()
            completion(nil)
        } catch { completion(error) }
    }

    public func zoomBounds() -> (Double, Double) {
        guard let d = currentDevice else { return (1, 1) }
        return (Double(d.minAvailableVideoZoomFactor), Double(d.maxAvailableVideoZoomFactor))
    }

    public func setExposureBias(_ ev: Double, completion: @escaping (Error?) -> Void) {
        guard let d = currentDevice else { completion(NSError(domain: "minis", code: -11)); return }
        do { try MinisManualControls.setExposureBias(device: d, ev: Float(ev)); completion(nil) } catch { completion(error) }
    }

    public func setManual(
        iso: Int?, shutterNs: Int64?, wbKelvin: Int?, lensPos: Double?,
        completion: @escaping (Error?) -> Void
    ) {
        guard let d = currentDevice else { completion(NSError(domain: "minis", code: -11)); return }
        do {
            try MinisManualControls.setManual(
                device: d,
                iso: iso.map { Float($0) },
                shutterNs: shutterNs,
                wbKelvin: wbKelvin,
                lensPosition: lensPos.map { Float($0) }
            )
            completion(nil)
        } catch { completion(error) }
    }

    public func tapToFocus(x: Double, y: Double, completion: @escaping (Error?) -> Void) {
        guard let d = currentDevice else { completion(NSError(domain: "minis", code: -11)); return }
        // Bias toward face centre if tap lands inside a detected face rect.
        var fx = x, fy = y
        if let faceHit = faceAnalyzer?.lastFaceRects.first(where: { r in
            let (rx, ry, rw, rh) = r
            return CGFloat(x) >= rx && CGFloat(x) <= rx + rw && CGFloat(y) >= ry && CGFloat(y) <= ry + rh
        }) {
            let (rx, ry, rw, rh) = faceHit
            fx = Double(rx + rw / 2)
            fy = Double(ry + rh / 2)
        }
        do { try MinisManualControls.setFocusPoint(device: d, point: CGPoint(x: fx, y: fy)); completion(nil) } catch { completion(error) }
    }

    public func setResolution(w: Int, h: Int, fps: Int, completion: @escaping (Bool, Error?) -> Void) {
        captureQueue.async {
            self.session.beginConfiguration()
            switch max(w, h) {
            case ...720: self.session.sessionPreset = .hd1280x720
            case ...1920: self.session.sessionPreset = .hd1920x1080
            default: if #available(iOS 9.0, *) { self.session.sessionPreset = .hd4K3840x2160 } else { self.session.sessionPreset = .high }
            }
            self.session.commitConfiguration()
            if fps > 30, let d = self.currentDevice {
                let res = MinisSlowMoController.enable(on: d, fps: fps)
                self.slowMoFps = res.actualFps
            }
            DispatchQueue.main.async { completion(true, nil) }
        }
    }

    public func enableHDR(_ on: Bool, completion: @escaping (Bool) -> Void) {
        guard let d = currentDevice else { completion(false); return }
        if on { hdrEnabled = MinisHDRController.enable(on: d); completion(hdrEnabled) }
        else { MinisHDRController.disable(on: d); hdrEnabled = false; completion(false) }
    }

    public func enableSlowMo(_ fps: Int, completion: @escaping (Bool, Int) -> Void) {
        guard let d = currentDevice else { completion(false, 0); return }
        let res = MinisSlowMoController.enable(on: d, fps: fps)
        slowMoFps = res.actualFps
        completion(res.enabled, res.actualFps)
    }

    public func enableTimeLapse(intervalMs: Int, durationMs: Int, completion: @escaping (Error?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minis_timelapse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ctrl = MinisTimeLapseController(workDir: dir) { [weak self] outPath, done in
            guard let self = self else { done(false); return }
            self.captureStill(raw: false, hdr: false) { path, _ in
                if let p = path {
                    // Copy/rename produced JPEG path → reserved slot.
                    try? FileManager.default.removeItem(atPath: outPath)
                    do {
                        try FileManager.default.moveItem(atPath: p, toPath: outPath)
                        done(true)
                    } catch { done(false) }
                } else { done(false) }
            }
        }
        timeLapseCtrl = ctrl
        ctrl.start(intervalMs: intervalMs, durationMs: durationMs) { [weak self] frames in
            guard let self = self else { return }
            if frames.isEmpty {
                self.emitState(state: "error", code: "TIMELAPSE_NO_FRAMES", message: nil)
                return
            }
            let out = dir.appendingPathComponent("minis_tl_\(Int(Date().timeIntervalSince1970)).mp4").path
            ctrl.stitchToMp4(outPath: out, fps: 30) { result in
                if let p = result {
                    self.emitState(state: "preview", code: "timeLapseFinalized", message: p)
                } else {
                    self.emitState(state: "error", code: "TIMELAPSE_STITCH_FAILED", message: nil)
                }
            }
        }
        completion(nil)
    }

    private var micGain: Double = 1.0

    public func setMic(deviceId: String?, gain: Double?, completion: @escaping (Error?) -> Void) {
        micGain = max(0.0, min(8.0, gain ?? 1.0))
        if let id = deviceId {
            let session = AVAudioSession.sharedInstance()
            if let target = session.availableInputs?.first(where: { $0.uid == id || $0.portName == id }) {
                do { try session.setPreferredInput(target); completion(nil); return }
                catch { completion(error); return }
            }
        }
        completion(nil)
    }

    public func listMics() -> [[String: Any]] {
        let session = AVAudioSession.sharedInstance()
        let curUid = session.preferredInput?.uid
        let inputs = session.availableInputs ?? []
        return inputs.map { p in
            [
                "id": p.uid,
                "label": p.portName,
                "type": "\(p.portType.rawValue)",
                "isDefault": p.uid == curUid,
            ]
        }
    }

    public func setRecordWithAudio(_ enabled: Boolean, completion: @escaping (Error?) -> Void) {
        withAudio = enabled
        completion(nil)
    }

    // MARK: - Recording

    public func startRecord(pathHint: String?, completion: @escaping (Error?) -> Void) {
        guard let rec = recorder else { completion(NSError(domain: "minis", code: -20)); return }
        let videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mp4) ?? [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ]
        let audioSettings: [String: Any]? = withAudio ?
            (audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) as? [String: Any]) : nil
        do {
            try rec.startSegment(videoSettings: videoSettings, audioSettings: audioSettings, withAudio: withAudio)
            sessionMachine.transition(to: .recording)
            completion(nil)
        } catch { completion(error) }
    }

    public func pauseRecord() { recorder?.pauseSegment(); sessionMachine.transition(to: .paused) }

    public func resumeRecord() {
        guard let rec = recorder else { return }
        let videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mp4) ?? [:]
        let audioSettings: [String: Any]? = withAudio ?
            (audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) as? [String: Any]) : nil
        try? rec.resumeSegment(videoSettings: videoSettings, audioSettings: audioSettings, withAudio: withAudio)
        sessionMachine.transition(to: .recording)
    }

    public func stopRecord(completion: @escaping (URL?, Int64, Int64, Error?) -> Void) {
        recorder?.stop { url in
            self.sessionMachine.transition(to: .stopped)
            let size = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? Int64 } ?? 0
            completion(url, 0, size, nil)
        }
    }

    public func finalizeClips(_ paths: [String], completion: @escaping (URL?, Error?) -> Void) {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("minis_merged_\(Int(Date().timeIntervalSince1970)).mp4")
        recorder?.finalizeMerged(to: out, completion: completion)
    }

    // MARK: - Photo

    public func captureStill(raw: Bool, hdr: Bool, completion: @escaping (String?, [String: Any]) -> Void) {
        let settings: AVCapturePhotoSettings
        if raw, let s = MinisRawCapture.rawSettings(on: photoOutput) {
            settings = s
            rawEnabled = true
        } else {
            settings = MinisRawCapture.jpegSettings(on: photoOutput, hdr: hdr)
        }
        pendingPhotoCallback = completion
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private var multiCamController: AnyObject?
    private var multiCamCompositor: AnyObject?
    private var multiCamPrimaryOut: AVCaptureVideoDataOutput?
    private var multiCamSecondaryOut: AVCaptureVideoDataOutput?
    private var multiCamPrimaryDel: AnyObject?
    private var multiCamSecondaryDel: AnyObject?
    private var multiCamOutPath: String?

    public func startMultiCam(_ layout: String, completion: @escaping (Error?) -> Void) {
        guard #available(iOS 13.0, *) else {
            completion(NSError(domain: "minis", code: -30, userInfo: [NSLocalizedDescriptionKey: "iOS 13+ required"]))
            return
        }
        do {
            let mc = MinisMultiCamController()
            _ = try mc.start()
            multiCamController = mc
            guard let session = mc.session else {
                completion(NSError(domain: "minis", code: -31, userInfo: [NSLocalizedDescriptionKey: "no multicam session"]))
                return
            }
            let lEnum = MinisMultiCamCompositor.Layout(rawValue: layout) ?? .topRight
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("minis_pip_\(Int(Date().timeIntervalSince1970)).mp4")
            multiCamOutPath = out.path
            let comp = MinisMultiCamCompositor(outURL: out, layout: lEnum)
            try comp.start()
            multiCamCompositor = comp

            let primaryOut = AVCaptureVideoDataOutput()
            let secondaryOut = AVCaptureVideoDataOutput()
            primaryOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            secondaryOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

            let primDel = MinisPipDelegate { [weak comp] sample in comp?.appendPrimary(sample) }
            let secDel = MinisPipDelegate { [weak comp] sample in comp?.appendSecondary(sample) }
            primaryOut.setSampleBufferDelegate(primDel, queue: DispatchQueue(label: "minis.pip.primary"))
            secondaryOut.setSampleBufferDelegate(secDel, queue: DispatchQueue(label: "minis.pip.secondary"))

            session.beginConfiguration()
            if session.canAddOutput(primaryOut) { session.addOutputWithNoConnections(primaryOut) }
            if session.canAddOutput(secondaryOut) { session.addOutputWithNoConnections(secondaryOut) }
            if let backIn = mc.backInput {
                let port = backIn.ports(for: .video, sourceDeviceType: nil, sourceDevicePosition: .back).first
                if let p = port {
                    let conn = AVCaptureConnection(inputPorts: [p], output: primaryOut)
                    if session.canAddConnection(conn) { session.addConnection(conn) }
                }
            }
            if let frontIn = mc.frontInput {
                let port = frontIn.ports(for: .video, sourceDeviceType: nil, sourceDevicePosition: .front).first
                if let p = port {
                    let conn = AVCaptureConnection(inputPorts: [p], output: secondaryOut)
                    if session.canAddConnection(conn) { session.addConnection(conn) }
                }
            }
            session.commitConfiguration()
            session.startRunning()

            multiCamPrimaryOut = primaryOut
            multiCamSecondaryOut = secondaryOut
            multiCamPrimaryDel = primDel
            multiCamSecondaryDel = secDel
            completion(nil)
        } catch { completion(error) }
    }

    public func stopMultiCam(completion: @escaping (String?, Error?) -> Void) {
        guard #available(iOS 13.0, *) else { completion(nil, nil); return }
        if let mc = multiCamController as? MinisMultiCamController { mc.stop() }
        multiCamController = nil
        if let comp = multiCamCompositor as? MinisMultiCamCompositor {
            comp.stop { path in
                self.multiCamCompositor = nil
                self.multiCamPrimaryOut = nil
                self.multiCamSecondaryOut = nil
                self.multiCamPrimaryDel = nil
                self.multiCamSecondaryDel = nil
                completion(path ?? self.multiCamOutPath, nil)
            }
        } else {
            completion(multiCamOutPath, nil)
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let gap = (Date().timeIntervalSince1970 - self.lastFrameAt) * 1000
            if gap > 250 {
                self.emitState(state: "error", code: "NO_FRAME", message: "no frame for \(Int(gap))ms")
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: - Release

    public func release() {
        watchdogTimer?.cancel(); watchdogTimer = nil
        session.stopRunning()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        recorder?.discard()
        recorder = nil
    }

    // MARK: - Emit helpers

    public func emitState(state: String, code: String?, message: String?) {
        DispatchQueue.main.async {
            self.stateSink?(["state": state, "code": code as Any, "message": message as Any])
        }
    }

    public func emitAudio(peak: Double, rms: Double) {
        DispatchQueue.main.async { self.audioLevelSink?(["peak": peak, "rms": rms]) }
    }
}

// MARK: - AVCapture delegates

extension MinisCameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lastFrameAt = Date().timeIntervalSince1970
        if output == videoOutput {
            recorder?.appendVideo(sampleBuffer)
            faceAnalyzer?.process(sampleBuffer)
        } else if output == audioOutput {
            // Optionally apply software gain in-place before recorder consumes.
            if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var lengthAtOffset = 0
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
                   let ptr = dataPointer {
                    let count = totalLength / MemoryLayout<Int16>.size
                    let samples = UnsafeMutableBufferPointer(start: UnsafeMutablePointer<Int16>(OpaquePointer(ptr)), count: count)
                    if micGain != 1.0 {
                        let g = micGain
                        for i in 0..<count {
                            let v = Double(samples[i]) * g
                            samples[i] = Int16(max(-32768.0, min(32767.0, v)))
                        }
                    }
                    var peak: Int16 = 0
                    var sumSq: Double = 0
                    for s in samples {
                        let a = abs(s)
                        if a > peak { peak = a }
                        sumSq += Double(s) * Double(s)
                    }
                    let rms = sqrt(sumSq / Double(max(count, 1))) / 32768.0
                    emitAudio(peak: Double(peak) / 32768.0, rms: rms)
                }
            }
            recorder?.appendAudio(sampleBuffer)
        }
    }
}

extension MinisCameraEngine: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let cb = pendingPhotoCallback
        pendingPhotoCallback = nil
        if let e = error { cb?(nil, ["error": e.localizedDescription]); return }
        let ext = (photo.isRawPhoto ? "dng" : "jpg")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minis_\(Int(Date().timeIntervalSince1970)).\(ext)")
        guard let data = photo.fileDataRepresentation() else { cb?(nil, [:]); return }
        do {
            try data.write(to: url)
            cb?(url.path, photo.metadata as? [String: Any] ?? [:])
        } catch { cb?(nil, [:]) }
    }
}

extension MinisCameraEngine: MinisCameraSessionListener {
    public func cameraSessionDidTransition(
        from prev: MinisCameraState, to next: MinisCameraState, code: String?, message: String?
    ) {
        emitState(state: next.rawValue, code: code, message: message)
    }
}

// Backwards compat alias to ease boolean param style in older callers.
public typealias Boolean = Bool
