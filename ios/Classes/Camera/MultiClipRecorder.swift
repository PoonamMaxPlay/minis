import AVFoundation
import Foundation

/// Per-clip `AVAssetWriter` recorder. `pause` finalises the current clip,
/// `resume` opens a new one. `finalize(merged:)` runs an `AVMutableComposition`
/// pass-through (no re-encode) so all segments concatenate into a single MP4.
public final class MinisMultiClipRecorder {

    public weak var sampleSource: MinisCameraEngine?

    public private(set) var segments: [URL] = []
    public private(set) var isRecording = false
    public private(set) var isPaused = false

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .zero
    private let workDir: URL
    private let indexURL: URL

    public init(workDir: URL) {
        self.workDir = workDir
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        self.indexURL = workDir.appendingPathComponent("segments.idx")
        recoverIfNeeded()
    }

    // MARK: - Lifecycle

    public func startSegment(videoSettings: [String: Any], audioSettings: [String: Any]?, withAudio: Bool) throws {
        guard writer == nil else { return }
        let segNumber = segments.count + 1
        let url = workDir.appendingPathComponent("seg_\(Int(Date().timeIntervalSince1970))_\(segNumber).mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vi.expectsMediaDataInRealTime = true
        if w.canAdd(vi) { w.add(vi) }
        if withAudio, let aSettings = audioSettings {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            ai.expectsMediaDataInRealTime = true
            if w.canAdd(ai) { w.add(ai) }
            audioInput = ai
        } else {
            audioInput = nil
        }
        writer = w
        videoInput = vi
        sessionStarted = false
        firstPTS = .invalid
        w.startWriting()
        isRecording = true
        isPaused = false
    }

    public func appendVideo(_ sample: CMSampleBuffer) {
        guard isRecording, !isPaused, let w = writer, let vi = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if !sessionStarted {
            firstPTS = pts
            w.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        if vi.isReadyForMoreMediaData {
            vi.append(sample)
            lastPTS = pts
        }
    }

    public func appendAudio(_ sample: CMSampleBuffer) {
        guard isRecording, !isPaused, let ai = audioInput else { return }
        if ai.isReadyForMoreMediaData {
            ai.append(sample)
        }
    }

    public func pauseSegment(completion: ((URL?) -> Void)? = nil) {
        guard isRecording, !isPaused, let w = writer else { completion?(nil); return }
        isPaused = true
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        w.finishWriting { [weak self] in
            guard let self = self else { completion?(nil); return }
            let outURL = w.outputURL
            self.segments.append(outURL)
            self.persistIndex()
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.sessionStarted = false
            completion?(outURL)
        }
    }

    public func resumeSegment(videoSettings: [String: Any], audioSettings: [String: Any]?, withAudio: Bool) throws {
        guard isPaused else { return }
        try startSegment(videoSettings: videoSettings, audioSettings: audioSettings, withAudio: withAudio)
    }

    public func stop(completion: @escaping (URL?) -> Void) {
        pauseSegment { url in
            self.isRecording = false
            self.isPaused = false
            completion(url ?? self.segments.last)
        }
    }

    // MARK: - Merge

    public func finalizeMerged(to out: URL, completion: @escaping (URL?, Error?) -> Void) {
        let urls = segments.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { completion(nil, NSError(domain: "minis", code: -1)); return }
        if urls.count == 1 {
            try? FileManager.default.removeItem(at: out)
            do {
                try FileManager.default.copyItem(at: urls[0], to: out)
                completion(out, nil); return
            } catch { completion(nil, error); return }
        }
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        for url in urls {
            let asset = AVAsset(url: url)
            let range = CMTimeRangeMake(start: .zero, duration: asset.duration)
            if let v = asset.tracks(withMediaType: .video).first {
                try? videoTrack?.insertTimeRange(range, of: v, at: cursor)
            }
            if let a = asset.tracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(range, of: a, at: cursor)
            }
            cursor = CMTimeAdd(cursor, asset.duration)
        }

        // Track-copy pass-through preset (no re-encode).
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            completion(nil, NSError(domain: "minis", code: -2)); return
        }
        try? FileManager.default.removeItem(at: out)
        exporter.outputURL = out
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                if exporter.status == .completed { completion(out, nil) }
                else { completion(nil, exporter.error) }
            }
        }
    }

    // MARK: - Index

    public func discard() {
        for s in segments { try? FileManager.default.removeItem(at: s) }
        segments.removeAll()
        try? FileManager.default.removeItem(at: indexURL)
    }

    private func persistIndex() {
        let body = segments.map { $0.path }.joined(separator: "\n")
        do {
            try body.write(to: indexURL, atomically: true, encoding: .utf8)
            // fsync via FileHandle to push to disk.
            if let h = try? FileHandle(forWritingTo: indexURL) {
                try? h.synchronize()
                try? h.close()
            }
        } catch { /* ignore */ }
    }

    private func recoverIfNeeded() {
        guard let body = try? String(contentsOf: indexURL, encoding: .utf8) else { return }
        for line in body.split(separator: "\n") {
            let p = String(line)
            if FileManager.default.fileExists(atPath: p) {
                segments.append(URL(fileURLWithPath: p))
            }
        }
    }

    public func totalDurationMs() -> Int64 {
        var total: Int64 = 0
        for u in segments {
            let asset = AVURLAsset(url: u)
            let d = CMTimeGetSeconds(asset.duration)
            if d.isFinite, d > 0 { total += Int64(d * 1000) }
        }
        return total
    }

    /// Scan a work directory for an orphaned `segments.idx` whose listed
    /// `.mp4` files parse via `AVURLAsset.load(.tracks)`. Returns valid paths
    /// + total duration in ms.
    public static func probeOrphans(workDir: URL) -> (paths: [String], totalMs: Int64) {
        let idx = workDir.appendingPathComponent("segments.idx")
        guard let body = try? String(contentsOf: idx, encoding: .utf8) else { return ([], 0) }
        var valid: [String] = []
        var total: Int64 = 0
        for line in body.split(separator: "\n") {
            let p = String(line)
            if !FileManager.default.fileExists(atPath: p) { continue }
            let asset = AVURLAsset(url: URL(fileURLWithPath: p))
            let secs = CMTimeGetSeconds(asset.duration)
            guard secs.isFinite, secs > 0, !asset.tracks.isEmpty else { continue }
            valid.append(p)
            total += Int64(secs * 1000)
        }
        return (valid, total)
    }
}
