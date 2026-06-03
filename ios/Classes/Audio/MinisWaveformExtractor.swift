import AVFoundation
import Flutter
import Foundation

/// AVAssetReader → 16-bit PCM mono-fold → fixed-count peak/RMS buckets.
final class MinisWaveformExtractor {
    private let queue = DispatchQueue(label: "minis.audio.waveform", qos: .utility)

    func extract(path: String, peakCount: Int, result: @escaping FlutterResult) {
        queue.async {
            do {
                let out = try self.run(path: path, peakCount: max(1, peakCount))
                DispatchQueue.main.async { result(out) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "MINIS_WAVEFORM",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func run(path: String, peakCount: Int) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let durationMs = Int(CMTimeGetSeconds(asset.duration) * 1000.0)

        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "MinisWaveform", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no audio track"])
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let bucket = DownsampleBucket(peakCount: peakCount)
        let channels = (track.formatDescriptions.first as! CMFormatDescription?)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            .map { Int($0) } ?? 1

        while reader.status == .reading {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else {
                CMSampleBufferInvalidate(buffer); continue
            }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block,
                                        atOffset: 0,
                                        lengthAtOffsetOut: nil,
                                        totalLengthOut: &length,
                                        dataPointerOut: &dataPointer)
            if let raw = dataPointer, length > 0 {
                raw.withMemoryRebound(to: Int16.self, capacity: length / 2) { ptr in
                    bucket.feed(ptr: ptr, sampleCount: length / 2, channels: channels)
                }
            }
            CMSampleBufferInvalidate(buffer)
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "MinisWaveform", code: -2,
                                          userInfo: [NSLocalizedDescriptionKey: "reader failed"])
        }
        let (peaks, rms) = bucket.finish()
        return [
            "peaks": peaks,
            "rms": rms,
            "durationMs": durationMs,
        ]
    }

    private final class DownsampleBucket {
        let peakCount: Int
        var peaks: [Double]
        var sumSq: [Double]
        var counts: [Int64]
        var bucketSize: Int64 = 1
        var cursor: Int = 0

        init(peakCount: Int) {
            self.peakCount = peakCount
            self.peaks = Array(repeating: 0.0, count: peakCount)
            self.sumSq = Array(repeating: 0.0, count: peakCount)
            self.counts = Array(repeating: 0, count: peakCount)
        }

        func feed(ptr: UnsafeMutablePointer<Int16>, sampleCount: Int, channels: Int) {
            let ch = max(1, channels)
            var i = 0
            while i + ch <= sampleCount {
                var sum: Int32 = 0
                for c in 0..<ch { sum &+= Int32(ptr[i + c]) }
                let mono = Double(sum) / Double(ch) / 32768.0
                push(absVal: abs(mono), signed: mono)
                i += ch
            }
        }

        private func push(absVal: Double, signed: Double) {
            growIfNeeded()
            let idx = min(cursor, peakCount - 1)
            if absVal > peaks[idx] { peaks[idx] = absVal }
            sumSq[idx] += signed * signed
            counts[idx] += 1
            if counts[idx] >= bucketSize {
                cursor = min(cursor + 1, peakCount - 1)
            }
        }

        private func growIfNeeded() {
            if cursor >= peakCount - 1 && counts[peakCount - 1] >= bucketSize {
                var w = 0
                var r = 0
                while r + 1 < peakCount {
                    peaks[w] = max(peaks[r], peaks[r + 1])
                    sumSq[w] = sumSq[r] + sumSq[r + 1]
                    counts[w] = counts[r] + counts[r + 1]
                    w += 1
                    r += 2
                }
                if r < peakCount {
                    peaks[w] = peaks[r]
                    sumSq[w] = sumSq[r]
                    counts[w] = counts[r]
                    w += 1
                }
                for i in w..<peakCount {
                    peaks[i] = 0
                    sumSq[i] = 0
                    counts[i] = 0
                }
                cursor = w
                bucketSize *= 2
            }
        }

        func finish() -> ([Double], [Double]) {
            var rms = Array(repeating: 0.0, count: peakCount)
            for i in 0..<peakCount {
                rms[i] = counts[i] > 0 ? (sumSq[i] / Double(counts[i])).squareRoot() : 0.0
            }
            return (peaks, rms)
        }
    }
}
