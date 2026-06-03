import Accelerate
import Foundation

/// Stateless DSP helpers for `MinisAudioMixer`.
/// Interleaved Float PCM in [-1, 1]. Stereo (ch == 2) assumed where panning is used.
enum MinisMixerHelpers {

    // MARK: Pan

    /// Constant-power pan. `pan` in [-1, 1]: -1 hard left, 0 center, +1 hard right.
    /// Returns (gainL, gainR).
    static func constantPowerPan(_ pan: Double) -> (Double, Double) {
        let p = max(-1.0, min(1.0, pan))
        let theta = (p + 1.0) * 0.25 * .pi  // 0..pi/2
        let l = cos(theta)
        let r = sin(theta)
        return (l, r)
    }

    static func applyPanEnvelope(_ samples: inout [Float], sr: Int, ch: Int, panEnv: [(Double, Double)]) {
        guard ch == 2, sr > 0, panEnv.count >= 1, !samples.isEmpty else { return }
        let env = panEnv.sorted { $0.0 < $1.0 }
        let frames = samples.count / 2
        for n in 0..<frames {
            let tMs = Double(n) * 1000.0 / Double(sr)
            let pan = envValue(tMs, env: env)
            let (gL, gR) = constantPowerPan(pan)
            let base = n * 2
            let l = Double(samples[base])
            let r = Double(samples[base + 1])
            samples[base] = Float(l * gL + r * (1.0 - gR))  // simple stereo-aware pan
            samples[base + 1] = Float(r * gR + l * (1.0 - gL))
        }
    }

    // MARK: EQ — RBJ biquad cascade per channel

    /// Three-band EQ: low-shelf @ 80 Hz, peak @ 1 kHz Q=1.0, high-shelf @ 8 kHz.
    /// Skips a band when dB == 0.
    static func applyEq(_ samples: inout [Float], sr: Int, ch: Int, lowDb: Double, midDb: Double, highDb: Double) {
        guard sr > 0, ch > 0, !samples.isEmpty else { return }
        let frames = samples.count / ch
        if frames <= 0 { return }

        var stages: [([Double], [Double])] = []
        if lowDb != 0 {
            stages.append(lowShelfCoeffs(sr: sr, f0: 80.0, q: 0.7071, gainDb: lowDb))
        }
        if midDb != 0 {
            stages.append(peakingCoeffs(sr: sr, f0: 1000.0, q: 1.0, gainDb: midDb))
        }
        if highDb != 0 {
            stages.append(highShelfCoeffs(sr: sr, f0: 8000.0, q: 0.7071, gainDb: highDb))
        }
        if stages.isEmpty { return }

        for c in 0..<ch {
            var chan = [Float](repeating: 0, count: frames)
            for n in 0..<frames { chan[n] = samples[n * ch + c] }
            for s in stages {
                biquadDF1InPlace(&chan, b: s.0, a: s.1)
            }
            for n in 0..<frames { samples[n * ch + c] = chan[n] }
        }
    }

    // MARK: Fades

    /// `kind`: linear | equalPower | exponential.
    static func fadeCurve(_ kind: String, _ t: Double) -> Double {
        let x = max(0.0, min(1.0, t))
        switch kind {
        case "equalPower":
            return sin(x * 0.5 * .pi)
        case "exponential":
            // -60 dB → 0 dB along [0,1].
            if x <= 0 { return 0 }
            return pow(10.0, (-60.0 * (1.0 - x)) / 20.0)
        default:
            return x
        }
    }

    static func applyFades(_ samples: inout [Float], sr: Int, ch: Int,
                           fadeInMs: Double, fadeOutMs: Double, kind: String = "linear") {
        guard sr > 0, ch > 0, !samples.isEmpty else { return }
        let frames = samples.count / ch
        if frames <= 0 { return }

        let fInFrames = max(0, Int(fadeInMs * Double(sr) / 1000.0))
        let fOutFrames = max(0, Int(fadeOutMs * Double(sr) / 1000.0))

        if fInFrames > 0 {
            let count = min(fInFrames, frames)
            for n in 0..<count {
                let g = Float(fadeCurve(kind, Double(n) / Double(max(1, count - 1))))
                let base = n * ch
                for c in 0..<ch { samples[base + c] *= g }
            }
        }
        if fOutFrames > 0 {
            let count = min(fOutFrames, frames)
            for i in 0..<count {
                let n = frames - 1 - i
                let g = Float(fadeCurve(kind, Double(i) / Double(max(1, count - 1))))
                let base = n * ch
                for c in 0..<ch { samples[base + c] *= g }
            }
        }
    }

    // MARK: Sidechain ducking

    /// Duck `music` whenever `voice` envelope crosses `thresholdDb` (peak follower with attack/release).
    /// Both arrays must have matching sr/ch/length.
    static func sidechainDuck(music: inout [Float], voice: [Float], sr: Int, ch: Int,
                              thresholdDb: Double = -30, attenDb: Double = -10,
                              attackMs: Double = 20, releaseMs: Double = 300) {
        guard sr > 0, ch > 0, !music.isEmpty, music.count == voice.count else { return }
        let frames = music.count / ch
        if frames <= 0 { return }

        let thr = pow(10.0, thresholdDb / 20.0)
        let duckLin = pow(10.0, attenDb / 20.0)  // e.g. -10 dB ≈ 0.316
        let attackCoef = expCoef(timeMs: attackMs, sr: sr)
        let releaseCoef = expCoef(timeMs: releaseMs, sr: sr)

        var env: Double = 0
        var gain: Double = 1.0

        for n in 0..<frames {
            // Voice peak across channels for this frame.
            var peak: Double = 0
            let base = n * ch
            for c in 0..<ch {
                let v = abs(Double(voice[base + c]))
                if v > peak { peak = v }
            }
            // Peak follower.
            if peak > env {
                env = attackCoef * (env - peak) + peak
            } else {
                env = releaseCoef * (env - peak) + peak
            }
            let target: Double = env > thr ? duckLin : 1.0
            let coef = target < gain ? attackCoef : releaseCoef
            gain = coef * (gain - target) + target
            let g = Float(gain)
            for c in 0..<ch {
                music[base + c] *= g
            }
        }
    }

    // MARK: Internals

    private static func expCoef(timeMs: Double, sr: Int) -> Double {
        let t = max(0.001, timeMs) / 1000.0
        return exp(-1.0 / (t * Double(sr)))
    }

    private static func envValue(_ tMs: Double, env: [(Double, Double)]) -> Double {
        if env.isEmpty { return 0 }
        if tMs <= env[0].0 { return env[0].1 }
        if tMs >= env[env.count - 1].0 { return env[env.count - 1].1 }
        var lo = 0
        var hi = env.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if env[mid].0 <= tMs { lo = mid } else { hi = mid }
        }
        let (t0, v0) = env[lo]
        let (t1, v1) = env[hi]
        if t1 == t0 { return v0 }
        let f = (tMs - t0) / (t1 - t0)
        return v0 + (v1 - v0) * f
    }

    // RBJ direct-form-I biquad, per-channel state local.
    private static func biquadDF1InPlace(_ x: inout [Float], b: [Double], a: [Double]) {
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

    private static func lowShelfCoeffs(sr: Int, f0: Double, q: Double, gainDb: Double) -> ([Double], [Double]) {
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * .pi * f0 / Double(sr)
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let sqrtA = sqrt(a)
        let b0 = a * ((a + 1) - (a - 1) * cosw + 2.0 * sqrtA * alpha)
        let b1 = 2.0 * a * ((a - 1) - (a + 1) * cosw)
        let b2 = a * ((a + 1) - (a - 1) * cosw - 2.0 * sqrtA * alpha)
        let a0 = (a + 1) + (a - 1) * cosw + 2.0 * sqrtA * alpha
        let a1 = -2.0 * ((a - 1) + (a + 1) * cosw)
        let a2 = (a + 1) + (a - 1) * cosw - 2.0 * sqrtA * alpha
        return ([b0 / a0, b1 / a0, b2 / a0], [1.0, a1 / a0, a2 / a0])
    }

    private static func highShelfCoeffs(sr: Int, f0: Double, q: Double, gainDb: Double) -> ([Double], [Double]) {
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * .pi * f0 / Double(sr)
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let sqrtA = sqrt(a)
        let b0 = a * ((a + 1) + (a - 1) * cosw + 2.0 * sqrtA * alpha)
        let b1 = -2.0 * a * ((a - 1) + (a + 1) * cosw)
        let b2 = a * ((a + 1) + (a - 1) * cosw - 2.0 * sqrtA * alpha)
        let a0 = (a + 1) - (a - 1) * cosw + 2.0 * sqrtA * alpha
        let a1 = 2.0 * ((a - 1) - (a + 1) * cosw)
        let a2 = (a + 1) - (a - 1) * cosw - 2.0 * sqrtA * alpha
        return ([b0 / a0, b1 / a0, b2 / a0], [1.0, a1 / a0, a2 / a0])
    }

    private static func peakingCoeffs(sr: Int, f0: Double, q: Double, gainDb: Double) -> ([Double], [Double]) {
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * .pi * f0 / Double(sr)
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosw
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosw
        let a2 = 1.0 - alpha / a
        return ([b0 / a0, b1 / a0, b2 / a0], [1.0, a1 / a0, a2 / a0])
    }
}
