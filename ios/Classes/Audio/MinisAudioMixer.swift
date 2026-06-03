import AVFoundation
import Flutter
import Foundation

struct MinisMixTrack {
    let path: String
    let inMs: Int
    let outMs: Int
    let positionMs: Int
    let gainEnv: [(Double, Double)] // (timeMs, linearGain)
    let panEnv: [(Double, Double)]
    let eqLowDb: Double
    let eqMidDb: Double
    let eqHighDb: Double
    let fadeInMs: Double
    let fadeOutMs: Double
    let fadeKind: String
    let isVoiceForDuck: Bool

    init(
        path: String, inMs: Int = 0, outMs: Int = 0, positionMs: Int = 0,
        gainEnv: [(Double, Double)] = [], panEnv: [(Double, Double)] = [],
        eqLowDb: Double = 0, eqMidDb: Double = 0, eqHighDb: Double = 0,
        fadeInMs: Double = 0, fadeOutMs: Double = 0, fadeKind: String = "linear",
        isVoiceForDuck: Bool = false
    ) {
        self.path = path; self.inMs = inMs; self.outMs = outMs; self.positionMs = positionMs
        self.gainEnv = gainEnv; self.panEnv = panEnv
        self.eqLowDb = eqLowDb; self.eqMidDb = eqMidDb; self.eqHighDb = eqHighDb
        self.fadeInMs = fadeInMs; self.fadeOutMs = fadeOutMs; self.fadeKind = fadeKind
        self.isVoiceForDuck = isVoiceForDuck
    }
}

/// Multitrack mix: decode → resample (linear) → gain-envelope → sum → optional LUFS normalize → AAC.
final class MinisAudioMixer {
    private let queue = DispatchQueue(label: "minis.audio.mix", qos: .utility)
    private let decoder = MinisPcmDecoder()
    private let encoder = MinisAacEncoder()

    func mix(
        tracks: [MinisMixTrack],
        outPath: String,
        targetLufs: Double,
        result: @escaping FlutterResult
    ) {
        queue.async {
            do {
                try self.run(tracks: tracks, outPath: outPath, targetLufs: targetLufs)
                DispatchQueue.main.async {
                    result(["taskId": UUID().uuidString, "path": outPath])
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "MINIS_AUDIO_MIX",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func run(tracks: [MinisMixTrack], outPath: String, targetLufs: Double) throws {
        guard !tracks.isEmpty else {
            throw NSError(domain: "MinisAudioMixer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no tracks"])
        }

        // Decode all.
        var decoded: [MinisDecodedPcm] = []
        decoded.reserveCapacity(tracks.count)
        for t in tracks {
            decoded.append(try decoder.decode(path: t.path))
        }

        let outRate = decoded[0].sampleRate
        let outCh = 2 // stereo output

        // Compute output frame count = max(positionMs + (outMs - inMs)) across tracks, in outRate frames.
        var maxEndMs = 0
        for t in tracks {
            let span = max(0, t.outMs - t.inMs)
            let endMs = t.positionMs + span
            if endMs > maxEndMs { maxEndMs = endMs }
        }
        let outFrames = max(1, Int((Double(maxEndMs) / 1000.0) * Double(outRate)) + 1)
        var music = [Float](repeating: 0.0, count: outFrames * outCh)
        var voice = [Float](repeating: 0.0, count: outFrames * outCh)
        var anyVoice = false
        var anyMusic = false

        for (i, t) in tracks.enumerated() {
            let src = decoded[i]
            var trackBuf = renderTrackBuffer(
                outFrames: outFrames, outRate: outRate, outCh: outCh,
                src: src, track: t
            )
            if t.eqLowDb != 0 || t.eqMidDb != 0 || t.eqHighDb != 0 {
                MinisMixerHelpers.applyEq(&trackBuf, sr: outRate, ch: outCh,
                                          lowDb: t.eqLowDb, midDb: t.eqMidDb, highDb: t.eqHighDb)
            }
            if !t.panEnv.isEmpty {
                MinisMixerHelpers.applyPanEnvelope(&trackBuf, sr: outRate, ch: outCh, panEnv: t.panEnv)
            }
            if t.fadeInMs > 0 || t.fadeOutMs > 0 {
                MinisMixerHelpers.applyFades(&trackBuf, sr: outRate, ch: outCh,
                                             fadeInMs: t.fadeInMs, fadeOutMs: t.fadeOutMs, kind: t.fadeKind)
            }
            if t.isVoiceForDuck {
                anyVoice = true
                for j in 0..<trackBuf.count { voice[j] += trackBuf[j] }
            } else {
                anyMusic = true
                for j in 0..<trackBuf.count { music[j] += trackBuf[j] }
            }
        }

        if anyVoice && anyMusic {
            MinisMixerHelpers.sidechainDuck(music: &music, voice: voice, sr: outRate, ch: outCh)
        }

        var out = [Float](repeating: 0.0, count: outFrames * outCh)
        for i in 0..<out.count { out[i] = music[i] + voice[i] }

        // Clip.
        for i in 0..<out.count {
            if out[i] > 1.0 { out[i] = 1.0 }
            else if out[i] < -1.0 { out[i] = -1.0 }
        }

        if targetLufs != 0 {
            let normalizer = MinisLufsNormalizer()
            _ = normalizer.normalizeInPlace(&out, sr: outRate, ch: outCh, targetLufs: targetLufs)
        }

        try encoder.encode(samples: out, sr: outRate, ch: outCh, outPath: outPath)
    }

    private func renderTrackBuffer(
        outFrames: Int, outRate: Int, outCh: Int,
        src: MinisDecodedPcm, track: MinisMixTrack
    ) -> [Float] {
        var buf = [Float](repeating: 0.0, count: outFrames * outCh)
        mixTrackInto(out: &buf, outFrames: outFrames, outRate: outRate, outCh: outCh,
                     src: src, track: track)
        return buf
    }

    private func mixTrackInto(
        out: inout [Float],
        outFrames: Int,
        outRate: Int,
        outCh: Int,
        src: MinisDecodedPcm,
        track: MinisMixTrack
    ) {
        let srcCh = max(1, src.channels)
        let srcRate = src.sampleRate
        let rateRatio = Double(srcRate) / Double(outRate)
        let inMs = max(0, track.inMs)
        let outMs = max(inMs, track.outMs)
        let srcFrames = src.samples.count / srcCh
        if srcFrames <= 0 { return }

        let inSampleSrc = Int(Double(inMs) * Double(srcRate) / 1000.0)
        let outSampleSrc = min(srcFrames, Int(Double(outMs) * Double(srcRate) / 1000.0))
        if outSampleSrc <= inSampleSrc { return }

        let spanFramesOut = Int(Double(outSampleSrc - inSampleSrc) / rateRatio)
        let posFrameOut = Int(Double(track.positionMs) * Double(outRate) / 1000.0)
        if posFrameOut >= outFrames { return }

        let env = track.gainEnv
        let envSorted = env.sorted { $0.0 < $1.0 }

        for n in 0..<spanFramesOut {
            let dstFrame = posFrameOut + n
            if dstFrame < 0 { continue }
            if dstFrame >= outFrames { break }

            let srcFracIdx = Double(inSampleSrc) + Double(n) * rateRatio
            let i0 = Int(srcFracIdx)
            let i1 = i0 + 1
            let frac = Float(srcFracIdx - Double(i0))
            if i0 < 0 || i1 >= srcFrames { continue }

            // Read source frame (interpolated), upmix mono→stereo.
            var l0: Float = 0, r0: Float = 0, l1: Float = 0, r1: Float = 0
            if srcCh == 1 {
                let a = src.samples[i0]
                let b = src.samples[i1]
                l0 = a; r0 = a
                l1 = b; r1 = b
            } else {
                let base0 = i0 * srcCh
                let base1 = i1 * srcCh
                l0 = src.samples[base0]
                r0 = src.samples[base0 + 1]
                l1 = src.samples[base1]
                r1 = src.samples[base1 + 1]
            }
            let l = l0 + (l1 - l0) * frac
            let r = r0 + (r1 - r0) * frac

            // Gain envelope at this output time.
            let curMs = Double(track.positionMs) + (Double(n) * 1000.0 / Double(outRate))
            let g = Float(envelopeAt(curMs, env: envSorted, defaultGain: 1.0))

            let dstBase = dstFrame * outCh
            out[dstBase] += l * g
            out[dstBase + 1] += r * g
        }
    }

    private func envelopeAt(_ tMs: Double, env: [(Double, Double)], defaultGain: Double) -> Double {
        if env.isEmpty { return defaultGain }
        if tMs <= env[0].0 { return env[0].1 }
        if tMs >= env[env.count - 1].0 { return env[env.count - 1].1 }
        var lo = 0
        var hi = env.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if env[mid].0 <= tMs { lo = mid } else { hi = mid }
        }
        let (t0, g0) = env[lo]
        let (t1, g1) = env[hi]
        if t1 == t0 { return g0 }
        let f = (tMs - t0) / (t1 - t0)
        return g0 + (g1 - g0) * f
    }
}
