// NOTE: AVAudioConverter emits raw Opus packets (no Ogg/MP4 muxing). Output is the
// concatenated raw packet payloads with no container — playback requires the original
// sr/ch metadata to be supplied out-of-band.

import AVFoundation
import Foundation

enum MinisOpusEncoderError: Error, LocalizedError {
    case unsupportedOS
    case formatInit
    case converterInit
    case bufferAlloc
    case fileWrite(Error)
    case encode(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return "Opus encoding requires iOS 13+."
        case .formatInit: return "AVAudioFormat init failed."
        case .converterInit: return "AVAudioConverter init failed (kAudioFormatOpus)."
        case .bufferAlloc: return "AVAudioBuffer allocation failed."
        case .fileWrite(let e): return "Opus file write failed: \(e.localizedDescription)"
        case .encode(let e): return "Opus encode failed: \(e.localizedDescription)"
        }
    }
}

final class MinisOpusEncoder {

    static func isAvailable() -> Bool {
        if #available(iOS 13.0, *) { return true }
        return false
    }

    func encode(samples: [Float], sr: Int, ch: Int, outPath: String) throws {
        guard #available(iOS 13.0, *) else { throw MinisOpusEncoderError.unsupportedOS }
        guard !samples.isEmpty, sr > 0, ch > 0 else { return }

        try? FileManager.default.removeItem(atPath: outPath)
        let dir = (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        FileManager.default.createFile(atPath: outPath, contents: nil, attributes: nil)
        guard let handle = FileHandle(forWritingAtPath: outPath) else {
            throw MinisOpusEncoderError.fileWrite(NSError(
                domain: "MinisOpusEncoder", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "cannot open \(outPath) for write"]
            ))
        }
        defer { try? handle.close() }

        // Source: interleaved Float32 PCM.
        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sr),
            channels: AVAudioChannelCount(ch),
            interleaved: true
        ) else { throw MinisOpusEncoderError.formatInit }

        // Destination: Opus. Opus only supports 8/12/16/24/48 kHz.
        let opusSr = nearestOpusSampleRate(sr)
        var dstAsbd = AudioStreamBasicDescription(
            mSampleRate: Float64(opusSr),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let dstFormat = AVAudioFormat(streamDescription: &dstAsbd) else {
            throw MinisOpusEncoderError.formatInit
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw MinisOpusEncoderError.converterInit
        }

        // Feed in chunks of ~20 ms at source rate.
        let chunkFrames = max(1, Int(0.02 * Double(sr)))
        let totalFrames = samples.count / ch
        var cursor = 0

        // Output packet capacity per pull: generous (4096 bytes is plenty for one Opus frame).
        let dstCapacity: AVAudioFrameCount = 4096

        while cursor < totalFrames {
            let take = min(chunkFrames, totalFrames - cursor)
            guard let srcBuf = AVAudioPCMBuffer(
                pcmFormat: srcFormat,
                frameCapacity: AVAudioFrameCount(take)
            ) else { throw MinisOpusEncoderError.bufferAlloc }
            srcBuf.frameLength = AVAudioFrameCount(take)
            if let dst = srcBuf.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { sp in
                    let base = sp.baseAddress!.advanced(by: cursor * ch)
                    dst.update(from: base, count: take * ch)
                }
            }
            cursor += take

            guard let dstBuf = AVAudioCompressedBuffer(
                format: dstFormat,
                packetCapacity: 8,
                maximumPacketSize: Int(dstCapacity)
            ) as AVAudioCompressedBuffer? else {
                throw MinisOpusEncoderError.bufferAlloc
            }

            var supplied = false
            var convError: NSError?
            let status = converter.convert(to: dstBuf, error: &convError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return srcBuf
            }

            if let e = convError {
                throw MinisOpusEncoderError.encode(e)
            }
            if status == .error {
                throw MinisOpusEncoderError.encode(NSError(
                    domain: "MinisOpusEncoder", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter returned .error"]
                ))
            }

            // Write packet bytes.
            let byteCount = Int(dstBuf.byteLength)
            if byteCount > 0 {
                let data = Data(bytes: dstBuf.data, count: byteCount)
                handle.write(data)
            }
        }

        // Flush — drain final packet.
        guard let dstBuf = AVAudioCompressedBuffer(
            format: dstFormat,
            packetCapacity: 8,
            maximumPacketSize: Int(dstCapacity)
        ) as AVAudioCompressedBuffer? else { return }
        var convError: NSError?
        _ = converter.convert(to: dstBuf, error: &convError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        let byteCount = Int(dstBuf.byteLength)
        if byteCount > 0 {
            let data = Data(bytes: dstBuf.data, count: byteCount)
            handle.write(data)
        }
    }

    private func nearestOpusSampleRate(_ sr: Int) -> Int {
        let allowed = [8000, 12000, 16000, 24000, 48000]
        var best = 48000
        var diff = Int.max
        for r in allowed {
            let d = abs(r - sr)
            if d < diff { diff = d; best = r }
        }
        return best
    }
}
