import Accelerate
import AVFoundation
import Flutter
import Foundation

/// Onset + BPM detection via STFT spectral flux + autocorrelation of onset intervals.
final class MinisBeatDetector {
    private let queue = DispatchQueue(label: "minis.audio.beats", qos: .utility)
    private let decoder = MinisPcmDecoder()

    private let fftSize = 1024
    private let hopSize = 512

    func detect(path: String, result: @escaping FlutterResult) {
        queue.async {
            do {
                let out = try self.run(path: path)
                DispatchQueue.main.async { result(out) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "MINIS_AUDIO_BEATS",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    private func run(path: String) throws -> [String: Any] {
        let decoded = try decoder.decode(path: path)
        let sr = decoded.sampleRate
        let ch = max(1, decoded.channels)

        // Downmix to mono.
        let frames = decoded.samples.count / ch
        var mono = [Float](repeating: 0, count: frames)
        if ch == 1 {
            mono = decoded.samples
        } else {
            for n in 0..<frames {
                var sum: Float = 0
                let base = n * ch
                for c in 0..<ch { sum += decoded.samples[base + c] }
                mono[n] = sum / Float(ch)
            }
        }

        if frames < fftSize {
            return ["bpm": 0.0, "onsetsMs": [Int]()]
        }

        // Hann window.
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // FFT setup (real-to-complex via vDSP_fft_zrip).
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "MinisBeatDetector", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "fft setup failed"])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var prevMag = [Float](repeating: 0, count: halfN)
        var flux: [Float] = []

        var pos = 0
        var windowed = [Float](repeating: 0, count: fftSize)
        while pos + fftSize <= frames {
            // Window.
            mono.withUnsafeBufferPointer { mp in
                vDSP_vmul(mp.baseAddress! + pos, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }
            // Pack to split complex.
            windowed.withUnsafeBufferPointer { wp in
                wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                    realp.withUnsafeMutableBufferPointer { rp in
                        imagp.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
                            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        }
                    }
                }
            }
            // Magnitude.
            var mag = [Float](repeating: 0, count: halfN)
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(halfN))
                }
            }
            // sqrt → linear magnitude.
            var count = Int32(halfN)
            var magLin = [Float](repeating: 0, count: halfN)
            vvsqrtf(&magLin, mag, &count)

            // Spectral flux: sum of positive diffs.
            var diff = [Float](repeating: 0, count: halfN)
            vDSP_vsub(prevMag, 1, magLin, 1, &diff, 1, vDSP_Length(halfN))
            var zero: Float = 0
            var rectified = [Float](repeating: 0, count: halfN)
            vDSP_vthr(diff, 1, &zero, &rectified, 1, vDSP_Length(halfN))
            var sum: Float = 0
            vDSP_sve(rectified, 1, &sum, vDSP_Length(halfN))
            flux.append(sum)

            prevMag = magLin
            pos += hopSize
        }

        if flux.isEmpty { return ["bpm": 0.0, "onsetsMs": [Int]()] }

        // Adaptive threshold: median over 0.5 s window × 1.5.
        let framesPerSec = Double(sr) / Double(hopSize)
        let medianWin = max(3, Int(0.5 * framesPerSec))
        let half = medianWin / 2
        var onsets: [Int] = []
        for i in 0..<flux.count {
            let lo = max(0, i - half)
            let hi = min(flux.count - 1, i + half)
            var slice = Array(flux[lo...hi])
            slice.sort()
            let med = slice[slice.count / 2]
            let thr = med * 1.5
            // Peak above threshold + local max.
            if flux[i] > thr {
                let leftOk = i == 0 || flux[i] >= flux[i - 1]
                let rightOk = i == flux.count - 1 || flux[i] >= flux[i + 1]
                if leftOk && rightOk {
                    onsets.append(i)
                }
            }
        }

        // Convert onsets to ms.
        let hopMs = 1000.0 * Double(hopSize) / Double(sr)
        let onsetsMs: [Int] = onsets.map { Int(Double($0) * hopMs) }

        // Tempo via autocorrelation of onset intervals (per-frame onset envelope).
        let rawBpm = estimateBpm(onsetFrames: onsets, framesPerSec: framesPerSec)
        var bpm = rawBpm
        if rawBpm > 0 {
            let envLen = (onsets.last ?? 0) + 1
            var env = [Float](repeating: 0, count: envLen)
            for f in onsets where f >= 0 && f < envLen { env[f] = 1.0 }
            bpm = MinisTempoRefiner.refine(candidateBpm: rawBpm, onsetEnvelope: env, envelopeRateHz: framesPerSec)
        }

        return ["bpm": bpm, "onsetsMs": onsetsMs]
    }

    private func estimateBpm(onsetFrames: [Int], framesPerSec: Double) -> Double {
        guard onsetFrames.count >= 4 else { return 0.0 }

        // Build a binary onset envelope at hop resolution.
        let lastFrame = onsetFrames.last!
        var env = [Float](repeating: 0, count: lastFrame + 1)
        for f in onsetFrames { env[f] = 1.0 }

        let bpmMin = 60.0
        let bpmMax = 200.0
        let lagMin = max(1, Int(60.0 / bpmMax * framesPerSec))
        let lagMax = min(env.count - 1, Int(60.0 / bpmMin * framesPerSec))
        if lagMax <= lagMin { return 0.0 }

        var bestLag = lagMin
        var bestVal: Float = -.infinity
        for lag in lagMin...lagMax {
            var acc: Float = 0
            let n = env.count - lag
            if n <= 0 { continue }
            env.withUnsafeBufferPointer { ep in
                vDSP_dotpr(ep.baseAddress!, 1, ep.baseAddress! + lag, 1, &acc, vDSP_Length(n))
            }
            if acc > bestVal {
                bestVal = acc
                bestLag = lag
            }
        }
        if bestVal <= 0 { return 0.0 }
        let bpm = 60.0 * framesPerSec / Double(bestLag)
        return bpm
    }
}
