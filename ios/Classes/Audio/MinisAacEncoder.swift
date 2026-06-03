import AVFoundation
import Foundation

enum MinisAacEncoderError: Error, LocalizedError {
    case writerInit(Error)
    case writerStartFailed(Error?)
    case writerFinishFailed(Error?)
    case bufferAllocFailed

    var errorDescription: String? {
        switch self {
        case .writerInit(let e): return "AVAssetWriter init failed: \(e.localizedDescription)"
        case .writerStartFailed(let e): return "writer start failed: \(e?.localizedDescription ?? "unknown")"
        case .writerFinishFailed(let e): return "writer finish failed: \(e?.localizedDescription ?? "unknown")"
        case .bufferAllocFailed: return "CMSampleBuffer allocation failed"
        }
    }
}

/// Encode interleaved Float PCM [-1,1] to .m4a (AAC 128k).
final class MinisAacEncoder {
    func encode(samples: [Float], sr: Int, ch: Int, outPath: String) throws {
        try? FileManager.default.removeItem(atPath: outPath)
        let dir = (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )
        let url = URL(fileURLWithPath: outPath)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw MinisAacEncoderError.writerInit(error)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: ch,
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw MinisAacEncoderError.writerStartFailed(nil)
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw MinisAacEncoderError.writerStartFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // Build interleaved Int16 from Float for source PCM buffers; encoder will reformat to AAC.
        // We feed via CMSampleBuffers chunked into ~4096-frame blocks.
        let frames = samples.count / max(1, ch)
        let chunkFrames = 4096
        let timescale: Int32 = Int32(sr)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sr),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * ch),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * ch),
            mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let fd = formatDesc else {
            throw MinisAacEncoderError.bufferAllocFailed
        }

        let sem = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "minis.audio.encode.feed")
        var cursorFrame = 0
        var feedError: Error?

        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if cursorFrame >= frames {
                    input.markAsFinished()
                    writer.finishWriting {
                        sem.signal()
                    }
                    return
                }
                let take = min(chunkFrames, frames - cursorFrame)
                let byteCount = take * ch * MemoryLayout<Float>.size
                var blockBuffer: CMBlockBuffer?
                let bbStatus = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: byteCount,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: byteCount,
                    flags: kCMBlockBufferAssureMemoryNowFlag,
                    blockBufferOut: &blockBuffer
                )
                guard bbStatus == noErr, let bb = blockBuffer else {
                    feedError = MinisAacEncoderError.bufferAllocFailed
                    input.markAsFinished()
                    writer.finishWriting { sem.signal() }
                    return
                }
                samples.withUnsafeBufferPointer { srcBuf in
                    let srcBase = srcBuf.baseAddress!.advanced(by: cursorFrame * ch)
                    CMBlockBufferReplaceDataBytes(
                        with: UnsafeRawPointer(srcBase),
                        blockBuffer: bb,
                        offsetIntoDestination: 0,
                        dataLength: byteCount
                    )
                }

                var sampleBuffer: CMSampleBuffer?
                let pts = CMTime(value: CMTimeValue(cursorFrame), timescale: timescale)
                let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: bb,
                    formatDescription: fd,
                    sampleCount: take,
                    presentationTimeStamp: pts,
                    packetDescriptions: nil,
                    sampleBufferOut: &sampleBuffer
                )
                guard createStatus == noErr, let sb = sampleBuffer else {
                    feedError = MinisAacEncoderError.bufferAllocFailed
                    input.markAsFinished()
                    writer.finishWriting { sem.signal() }
                    return
                }
                if !input.append(sb) {
                    feedError = writer.error
                    input.markAsFinished()
                    writer.finishWriting { sem.signal() }
                    return
                }
                cursorFrame += take
            }
        }

        sem.wait()
        if let e = feedError {
            throw MinisAacEncoderError.writerFinishFailed(e)
        }
        if writer.status != .completed {
            throw MinisAacEncoderError.writerFinishFailed(writer.error)
        }
    }
}
