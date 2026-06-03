package com.loopit.minis.audio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Disambiguates BPM octave errors from autocorrelation. Builds a periodic
 * comb at multiples + subharmonics of each candidate (the source BPM and
 * 0.5×, 2×, 3× variants) and picks the one whose comb energy in the
 * onset envelope is highest while landing in [60, 200].
 */
object TempoRefiner {

    private const val MIN_BPM = 60.0
    private const val MAX_BPM = 200.0

    fun refine(candidateBpm: Double, onsetEnvelope: FloatArray, envelopeRateHz: Double): Double {
        if (onsetEnvelope.isEmpty() || envelopeRateHz <= 0.0 || candidateBpm <= 0.0) return candidateBpm

        // Try the candidate plus common octave/triplet errors.
        val factors = doubleArrayOf(0.5, 2.0 / 3.0, 1.0, 4.0 / 3.0, 1.5, 2.0, 3.0)
        var best = candidateBpm.coerceIn(MIN_BPM, MAX_BPM)
        var bestScore = -Double.MAX_VALUE

        for (f in factors) {
            val bpm = candidateBpm * f
            val mapped = mapInRange(bpm)
            if (mapped <= 0.0) continue
            val score = combScore(onsetEnvelope, envelopeRateHz, mapped)
            if (score > bestScore) { bestScore = score; best = mapped }
        }
        return best
    }

    /** Wrap a BPM into [60,200] by halving/doubling. */
    private fun mapInRange(bpm: Double): Double {
        var b = bpm
        var guard = 0
        while (b < MIN_BPM && guard < 8) { b *= 2.0; guard++ }
        while (b > MAX_BPM && guard < 16) { b *= 0.5; guard++ }
        return if (b in MIN_BPM..MAX_BPM) b else -1.0
    }

    /**
     * Comb filter score: sum env at multiples of the beat period, minus
     * energy at off-grid offsets (anti-syncopation penalty). Includes
     * subharmonic half-beat reinforcement.
     */
    private fun combScore(env: FloatArray, rate: Double, bpm: Double): Double {
        val period = 60.0 * rate / bpm
        if (period <= 1.0 || period * 2 >= env.size) return -Double.MAX_VALUE
        val n = env.size
        val halfWin = max(1, (period * 0.05).roundToInt())
        // Sum of env around k*period for k=1..K with Hann taper.
        val maxK = (n / period).toInt().coerceAtMost(64)
        if (maxK < 2) return -Double.MAX_VALUE
        var on = 0.0
        var off = 0.0
        var k = 1
        while (k <= maxK) {
            val center = (k * period).roundToInt()
            if (center >= n) break
            val taper = 1.0 - (k - 1).toDouble() / maxK // earlier beats weighted higher
            var i = -halfWin
            while (i <= halfWin) {
                val idx = center + i
                if (idx in 0 until n) {
                    val w = 0.5 - 0.5 * cos(PI * (i + halfWin) / (2.0 * halfWin))
                    on += env[idx] * w * taper
                }
                i++
            }
            // Off-grid offset (quarter-period away) penalty.
            val offCenter = center + (period / 2.0).roundToInt()
            if (offCenter in 0 until n) off += env[offCenter] * taper
            k++
        }
        // Subharmonic reinforcement: half-period must also show energy.
        var sub = 0.0
        val halfPeriod = (period * 0.5).roundToInt()
        var j = halfPeriod
        while (j < n) {
            sub += env[j]
            j += (period).roundToInt().coerceAtLeast(1)
        }
        return on + 0.25 * sub - 0.5 * off
    }
}
