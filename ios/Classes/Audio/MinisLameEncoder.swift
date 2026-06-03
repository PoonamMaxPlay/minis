import Foundation
import Darwin

/// MP3 encoder backed by libmp3lame.a (vendored under ios/Vendor/lame/).
/// Mirrors Android's LameStub: probes via dlsym so the class compiles + loads
/// even when the static library hasn't been linked yet. When `isAvailable()`
/// returns false, the iOS Recorder MP3 path throws a named NSError.
///
/// Run `ios/scripts/fetch_lame.sh` once to fetch+build LAME 3.100 fat static
/// and add the three lines to the podspec listed by the script.
final class MinisLameEncoder {

    private typealias LameInit = @convention(c) () -> OpaquePointer?
    private typealias LameSetInSamplerate = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias LameSetNumChannels = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias LameSetBrate = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias LameInitParams = @convention(c) (OpaquePointer?) -> Int32
    private typealias LameEncodeBufferIeeeFloat = @convention(c) (
        OpaquePointer?, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32,
        UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32
    private typealias LameEncodeBufferInterleavedIeeeFloat = @convention(c) (
        OpaquePointer?, UnsafePointer<Float>?, Int32,
        UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32
    private typealias LameEncodeFlush = @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32
    private typealias LameClose = @convention(c) (OpaquePointer?) -> Int32

    static func isAvailable() -> Bool {
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "lame_init") != nil
    }

    func encode(samples: [Float], sr: Int, ch: Int, outPath: String) throws {
        guard MinisLameEncoder.isAvailable() else {
            throw NSError(domain: "MinisLameEncoder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "libmp3lame symbols missing — run ios/scripts/fetch_lame.sh and add the 3 podspec lines",
            ])
        }
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
        guard
            let pInit = dlsym(RTLD_DEFAULT, "lame_init"),
            let pSetSr = dlsym(RTLD_DEFAULT, "lame_set_in_samplerate"),
            let pSetCh = dlsym(RTLD_DEFAULT, "lame_set_num_channels"),
            let pSetBr = dlsym(RTLD_DEFAULT, "lame_set_brate"),
            let pInitParams = dlsym(RTLD_DEFAULT, "lame_init_params"),
            let pEncInterleaved = dlsym(RTLD_DEFAULT, "lame_encode_buffer_interleaved_ieee_float"),
            let pEncMono = dlsym(RTLD_DEFAULT, "lame_encode_buffer_ieee_float"),
            let pFlush = dlsym(RTLD_DEFAULT, "lame_encode_flush"),
            let pClose = dlsym(RTLD_DEFAULT, "lame_close")
        else {
            throw NSError(domain: "MinisLameEncoder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "lame symbol resolution failed",
            ])
        }
        let lameInit = unsafeBitCast(pInit, to: LameInit.self)
        let setSr = unsafeBitCast(pSetSr, to: LameSetInSamplerate.self)
        let setCh = unsafeBitCast(pSetCh, to: LameSetNumChannels.self)
        let setBr = unsafeBitCast(pSetBr, to: LameSetBrate.self)
        let initParams = unsafeBitCast(pInitParams, to: LameInitParams.self)
        let encInterleaved = unsafeBitCast(pEncInterleaved, to: LameEncodeBufferInterleavedIeeeFloat.self)
        let encMono = unsafeBitCast(pEncMono, to: LameEncodeBufferIeeeFloat.self)
        let flush = unsafeBitCast(pFlush, to: LameEncodeFlush.self)
        let close = unsafeBitCast(pClose, to: LameClose.self)

        guard let gfp = lameInit() else {
            throw NSError(domain: "MinisLameEncoder", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "lame_init failed"])
        }
        defer { _ = close(gfp) }
        _ = setSr(gfp, Int32(sr))
        _ = setCh(gfp, Int32(ch))
        _ = setBr(gfp, 192)
        guard initParams(gfp) >= 0 else {
            throw NSError(domain: "MinisLameEncoder", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "lame_init_params failed"])
        }

        FileManager.default.createFile(atPath: outPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outPath) else {
            throw NSError(domain: "MinisLameEncoder", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(outPath) for write"])
        }
        defer { handle.closeFile() }

        let frames = samples.count / max(1, ch)
        let chunkFrames = 1152
        var mp3Buf = [UInt8](repeating: 0, count: max(8192, chunkFrames * 5 / 4 + 7200))

        var off = 0
        while off < frames {
            let n = min(chunkFrames, frames - off)
            let written: Int32 = samples.withUnsafeBufferPointer { srcPtr in
                mp3Buf.withUnsafeMutableBufferPointer { dstPtr in
                    if ch == 1 {
                        let base = srcPtr.baseAddress!.advanced(by: off)
                        return encMono(gfp, base, base, Int32(n), dstPtr.baseAddress, Int32(dstPtr.count))
                    } else {
                        let base = srcPtr.baseAddress!.advanced(by: off * ch)
                        return encInterleaved(gfp, base, Int32(n), dstPtr.baseAddress, Int32(dstPtr.count))
                    }
                }
            }
            if written < 0 {
                throw NSError(domain: "MinisLameEncoder", code: -6,
                              userInfo: [NSLocalizedDescriptionKey: "lame_encode failed code=\(written)"])
            }
            if written > 0 {
                handle.write(Data(mp3Buf.prefix(Int(written))))
            }
            off += n
        }
        let tail: Int32 = mp3Buf.withUnsafeMutableBufferPointer { dstPtr in
            flush(gfp, dstPtr.baseAddress, Int32(dstPtr.count))
        }
        if tail > 0 {
            handle.write(Data(mp3Buf.prefix(Int(tail))))
        }
    }
}
