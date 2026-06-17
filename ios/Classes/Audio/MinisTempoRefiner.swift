import Foundation

/// Harmonic-comb tempo refinement: score 2×, 3×, 4× harmonics and 0.5×, 0.33×
/// subharmonics of a candidate BPM against the onset envelope autocorrelation,
/// and pick the multiple whose comb score is highest while staying in [60, 200] BPM.
enum MinisTempoRefiner {

    static func refine(candidateBpm: Double, onsetEnvelope: [Float], envelopeRateHz: Double) -> Double {
        guard candidateBpm > 0, envelopeRateHz > 0, onsetEnvelope.count > 8 else {
            return candidateBpm
        }

        // Pre-compute autocorrelation r(lag) over the full plausible range.
        let bpmHardMin = 30.0
        let bpmHardMax = 400.0
        let lagMin = max(1, Int(60.0 * envelopeRateHz / bpmHardMax))
        let lagMax = min(onsetEnvelope.count - 1, Int(60.0 * envelopeRateHz / bpmHardMin))
        if lagMax <= lagMin { return candidateBpm }

        var ac = [Float](repeating: 0, count: lagMax + 1)
        for lag in lagMin...lagMax {
            var s: Float = 0
            let n = onsetEnvelope.count - lag
            if n <= 0 { continue }
            for i in 0..<n {
                s += onsetEnvelope[i] * onsetEnvelope[i + lag]
            }
            ac[lag] = s
        }
        // Normalize.
        var peak: Float = 0
        for v in ac where v > peak { peak = v }
        if peak <= 0 { return candidateBpm }
        for i in 0..<ac.count { ac[i] /= peak }

        let candidates: [Double] = [
            candidateBpm * 0.5,
            candidateBpm / 3.0,
            candidateBpm,
            candidateBpm * 2.0,
            candidateBpm * 3.0,
            candidateBpm * 4.0,
        ]

        var best = candidateBpm
        var bestScore: Double = -.infinity
        for bpm in candidates {
            if bpm < 60.0 || bpm > 200.0 { continue }
            let score = combScore(bpm: bpm, ac: ac, lagMin: lagMin, lagMax: lagMax,
                                  envelopeRateHz: envelopeRateHz)
            if score > bestScore {
                bestScore = score
                best = bpm
            }
        }

        // If candidate itself is out of [60,200], still pick the best in-range we found;
        // otherwise return the candidate untouched.
        if bestScore == -.infinity { return candidateBpm }
        return best
    }

    private static func combScore(bpm: Double, ac: [Float], lagMin: Int, lagMax: Int,
                                  envelopeRateHz: Double) -> Double {
        let base = 60.0 * envelopeRateHz / bpm
        let multiples: [(Double, Double)] = [
            (1.0, 1.0), (2.0, 0.6), (3.0, 0.4), (4.0, 0.3),
            (0.5, 0.5), (1.0 / 3.0, 0.3),
        ]
        var sum: Double = 0
        var weightSum: Double = 0
        for (m, w) in multiples {
            let lagF = base * m
            let lag = Int(lagF.rounded())
            if lag < lagMin || lag > lagMax { continue }
            // Local max over ±2 bins to absorb quantization.
            var v: Float = ac[lag]
            for d in 1...2 {
                let li = lag - d
                let lj = lag + d
                if li >= lagMin && ac[li] > v { v = ac[li] }
                if lj <= lagMax && ac[lj] > v { v = ac[lj] }
            }
            sum += Double(v) * w
            weightSum += w
        }
        if weightSum == 0 { return -.infinity }
        return sum / weightSum
    }
}
