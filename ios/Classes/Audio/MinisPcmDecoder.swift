import AVFoundation
import Foundation

/// Decode any AVAsset-readable audio file to interleaved Float PCM at source rate.
/// Mono stays mono; multi-channel is preserved (caller may downmix/upmix).
struct MinisDecodedPcm {
    let samples: [Float]
    let sampleRate: Int
    let channels: Int
}

enum MinisPcmDecoderError: Error, LocalizedError {
    case noAudioTrack
    case readerInit(Error)
    case readerFailed(Error?)
    case noFormat

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "no audio track"
        case .readerInit(let e): return "AVAssetReader init failed: \(e.localizedDescription)"
        case .readerFailed(let e): return "reader failed: \(e?.localizedDescription ?? "unknown")"
        case .noFormat: return "no audio format description"
        }
    }
}

final class MinisPcmDecoder {
    func decode(path: String) throws -> MinisDecodedPcm {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw MinisPcmDecoderError.noAudioTrack
        }
        guard let fdRaw = track.formatDescriptions.first else {
            throw MinisPcmDecoderError.noFormat
        }
        let fd = fdRaw as! CMFormatDescription
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else {
            throw MinisPcmDecoderError.noFormat
        }
        let asbd = asbdPtr.pointee
        let srcRate = Int(asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100)
        let channels = Int(asbd.mChannelsPerFrame > 0 ? asbd.mChannelsPerFrame : 1)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MinisPcmDecoderError.readerInit(error)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: srcRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MinisPcmDecoderError.readerFailed(nil)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MinisPcmDecoderError.readerFailed(reader.error)
        }

        var samples = [Float]()
        let approxFrames = Int(CMTimeGetSeconds(asset.duration) * Double(srcRate))
        if approxFrames > 0 {
            samples.reserveCapacity(approxFrames * channels)
        }

        while reader.status == .reading {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else {
                CMSampleBufferInvalidate(buffer); continue
            }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            if let raw = dataPointer, length > 0 {
                let floatCount = length / MemoryLayout<Float>.size
                raw.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
                    let bp = UnsafeBufferPointer(start: ptr, count: floatCount)
                    samples.append(contentsOf: bp)
                }
            }
            CMSampleBufferInvalidate(buffer)
        }

        if reader.status == .failed {
            throw MinisPcmDecoderError.readerFailed(reader.error)
        }

        return MinisDecodedPcm(samples: samples, sampleRate: srcRate, channels: channels)
    }
}
