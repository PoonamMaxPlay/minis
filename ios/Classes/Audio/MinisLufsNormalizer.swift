import AVFoundation
import Flutter
import Foundation

/// ITU-R BS.1770-4 integrated loudness measurement + scalar gain normalization.
/// Uses two-stage K-weighting (high-shelf 1681 Hz pre-filter + 38 Hz RLB high-pass),
/// 400 ms blocks, 75% overlap, absolute -70 LUFS gate, relative -10 LU gate.
final class MinisLufsNormalizer {
    private let queue = DispatchQueue(label: "minis.audio.lufs", qos: .utility)
    private let decoder = MinisPcmDecoder()
    private let encoder = MinisAacEncoder()

    // MARK: Public API

    func measureLufs(samples: [Float], sr: Int, ch: Int) -> Double {
        return computeIntegratedLufs(samples: samples, sr: sr, ch: max(1, ch))
    }

    /// Applies scalar gain so integrated loudness ≈ targetLufs. Returns measured input LUFS.
    @discardableResult
    func normalizeInPlace(_ samples: inout [Float], sr: Int, ch: Int, targetLufs: Double) -> Double {
        let measured = computeIntegratedLufs(samples: samples, sr: sr, ch: max(1, ch))
        if !measured.isFinite { return measured }
        let deltaDb = targetLufs - measured
        let gain = Float(pow(10.0, deltaDb / 20.0))
        if gain == 1.0 { return measured }
        // Apply, then clip.
        for i in 0..<samples.count {
            var v = samples[i] * gain
            if v > 1.0 { v = 1.0 }
            else if v < -1.0 { v = -1.0 }
            samples[i] = v
        }
        return measured
    }

    func normalize(path: String, outPath: String, targetLufs: Double, result: @escaping FlutterResult) {
        queue.async {
            do {
                let decoded = try self.decoder.decode(path: path)
                var samples = decoded.samples
                let measured = self.normalizeInPlace(
                    &samples,
                    sr: decoded.sampleRate,
                    ch: decoded.channels,
                    targetLufs: targetLufs
                )
                try self.encoder.encode(
                    samples: samples,
                    sr: decoded.sampleRate,
                    ch: decoded.channels,
                    outPath: outPath
                )
                DispatchQueue.main.async {
                    result(["path": outPath, "measuredLufs": measured, "targetLufs": targetLufs])
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "MINIS_AUDIO_NORMALIZE",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    // MARK: Core measurement

    private func computeIntegratedLufs(samples: [Float], sr: Int, ch: Int) -> Double {
        guard !samples.isEmpty, sr > 0, ch > 0 else { return -.infinity }
        let frames = samples.count / ch
        if frames < 1 { return -.infinity }

        // De-interleave + K-weight each channel.
        var weighted = [[Float]](repeating: [], count: ch)
        for c in 0..<ch {
            var chan = [Float](repeating: 0, count: frames)
            for n in 0..<frames {
                chan[n] = samples[n * ch + c]
            }
            applyKWeighting(&chan, sr: sr)
            weighted[c] = chan
        }

        let blockSize = Int(0.4 * Double(sr))
        let stepSize = Int(0.1 * Double(sr))
        if blockSize <= 0 || frames < blockSize { return -.infinity }

        // Channel weights G_i: L=R=1.0, others=1.0 (we treat all as 1.0 per spec for stereo).
        // BS.1770 specifies L=R=1.0, C=1.0, Ls=Rs=1.41; here we use 1.0 for ch<=2, 1.0 fallback otherwise.
        var gWeights = [Double](repeating: 1.0, count: ch)
        if ch >= 5 {
            gWeights[3] = 1.41
            gWeights[4] = 1.41
        }

        var blockLoudnesses: [Double] = []
        var blockMeanSqs: [Double] = []
        var start = 0
        while start + blockSize <= frames {
            var meanSqSum: Double = 0
            for c in 0..<ch {
                let chan = weighted[c]
                var acc: Double = 0
                for n in start..<(start + blockSize) {
                    let v = Double(chan[n])
                    acc += v * v
                }
                let meanSq = acc / Double(blockSize)
                meanSqSum += gWeights[c] * meanSq
            }
            blockMeanSqs.append(meanSqSum)
            let loudness: Double
            if meanSqSum > 0 {
                loudness = -0.691 + 10.0 * log10(meanSqSum)
            } else {
                loudness = -.infinity
            }
            blockLoudnesses.append(loudness)
            start += stepSize
        }

        if blockLoudnesses.isEmpty { return -.infinity }

        // Absolute gate at -70 LUFS.
        var keptMeanSqs: [Double] = []
        for (i, l) in blockLoudnesses.enumerated() {
            if l >= -70.0 { keptMeanSqs.append(blockMeanSqs[i]) }
        }
        if keptMeanSqs.isEmpty { return -.infinity }

        // Relative gate at (ungated mean loudness) - 10 LU.
        let meanSq1 = keptMeanSqs.reduce(0.0, +) / Double(keptMeanSqs.count)
        let l1 = meanSq1 > 0 ? -0.691 + 10.0 * log10(meanSq1) : -.infinity
        let relGate = l1 - 10.0

        var finalMeanSqs: [Double] = []
        for (i, l) in blockLoudnesses.enumerated() {
            if l >= -70.0 && l >= relGate {
                finalMeanSqs.append(blockMeanSqs[i])
            }
        }
        if finalMeanSqs.isEmpty { return l1 }
        let meanSq2 = finalMeanSqs.reduce(0.0, +) / Double(finalMeanSqs.count)
        let integrated = meanSq2 > 0 ? -0.691 + 10.0 * log10(meanSq2) : -.infinity
        return integrated
    }

    // MARK: K-weighting (RBJ biquad cascade)

    private func applyKWeighting(_ x: inout [Float], sr: Int) {
        let (b1, a1) = preFilterCoeffs(sr: sr)
        let (b2, a2) = rlbFilterCoeffs(sr: sr)
        biquadInPlace(&x, b: b1, a: a1)
        biquadInPlace(&x, b: b2, a: a2)
    }

    /// High-shelf at 1681.974450955533 Hz, +4 dB (BS.1770 pre-filter; common ref coeffs).
    private func preFilterCoeffs(sr: Int) -> ([Double], [Double]) {
        // Reference coefficients (Brecht De Man) for 48kHz; we re-derive via RBJ for arbitrary sr.
        let f0 = 1681.974450955533
        let g: Double = 3.999843853973347 // ~4 dB
        let q: Double = 0.7071752369554196
        let a = pow(10.0, g / 40.0)
        let w0 = 2.0 * .pi * f0 / Double(sr)
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let twoSqrtAalpha = 2.0 * sqrt(a) * alpha
        let b0 = a * ((a + 1) + (a - 1) * cosw + twoSqrtAalpha)
        let b1 = -2.0 * a * ((a - 1) + (a + 1) * cosw)
        let b2 = a * ((a + 1) + (a - 1) * cosw - twoSqrtAalpha)
        let a0 = (a + 1) - (a - 1) * cosw + twoSqrtAalpha
        let a1 = 2.0 * ((a - 1) - (a + 1) * cosw)
        let a2 = (a + 1) - (a - 1) * cosw - twoSqrtAalpha
        return ([b0 / a0, b1 / a0, b2 / a0], [1.0, a1 / a0, a2 / a0])
    }

    /// RLB high-pass at 38.13547087602444 Hz (BS.1770 stage 2).
    private func rlbFilterCoeffs(sr: Int) -> ([Double], [Double]) {
        let f0 = 38.13547087602444
        let q: Double = 0.5003270373238773
        let w0 = 2.0 * .pi * f0 / Double(sr)
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let b0 = (1.0 + cosw) / 2.0
        let b1 = -(1.0 + cosw)
        let b2 = (1.0 + cosw) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosw
        let a2 = 1.0 - alpha
        return ([b0 / a0, b1 / a0, b2 / a0], [1.0, a1 / a0, a2 / a0])
    }

    private func biquadInPlace(_ x: inout [Float], b: [Double], a: [Double]) {
        let b0 = b[0], b1 = b[1], b2 = b[2]
        let a1 = a[1], a2 = a[2]
        var x1: Double = 0, x2: Double = 0
        var y1: Double = 0, y2: Double = 0
        for i in 0..<x.count {
            let xn = Double(x[i])
            let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
            x[i] = Float(yn)
        }
    }
}
