package com.loopit.minis.audio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Stateless DSP helpers shared with `AudioMixer`. All sample buffers are
 * interleaved float frames in [-1, 1]. Stereo unless noted.
 */
object MixerHelpers {

    private const val EPS = 1e-12

    /** Constant-power pan. pan in [-1,1]; returns (gainL, gainR). */
    fun constantPowerPan(pan: Double): Pair<Double, Double> {
        val p = pan.coerceIn(-1.0, 1.0)
        // Map [-1,1] → angle [0, PI/2]; equal-power preserves L^2 + R^2 = 1.
        val theta = (p + 1.0) * 0.25 * PI
        return cos(theta) to sin(theta)
    }

    /**
     * Apply 3-band biquad EQ in place on interleaved float frames. Low-shelf
     * @80 Hz, peaking @1 kHz (Q=1), high-shelf @8 kHz. Bands with 0 dB are
     * skipped.
     */
    fun applyEq(samples: FloatArray, sr: Int, ch: Int, lowDb: Double, midDb: Double, highDb: Double) {
        if (samples.isEmpty() || ch <= 0) return
        if (lowDb == 0.0 && midDb == 0.0 && highDb == 0.0) return
        val bands = ArrayList<Biquad>(3)
        if (lowDb != 0.0) bands.add(lowShelf(sr, 80.0, lowDb))
        if (midDb != 0.0) bands.add(peaking(sr, 1000.0, 1.0, midDb))
        if (highDb != 0.0) bands.add(highShelf(sr, 8000.0, highDb))
        if (bands.isEmpty()) return
        for (band in bands) applyBiquadInterleaved(samples, ch, band)
    }

    /** Fade curve: t in [0,1]. */
    fun fadeCurve(kind: String, t: Double): Double {
        val u = t.coerceIn(0.0, 1.0)
        return when (kind) {
            "equalPower" -> sin(u * PI * 0.5)
            "exponential" -> if (u <= 0.0) 0.0 else exp((u - 1.0) * 6.0) // ~-52 dB → 0 dB
            else -> u // linear
        }
    }

    /**
     * Sidechain duck: when voice loudness exceeds threshold, attenuate music
     * over `attackMs`; restore over `releaseMs`. Single-pole envelope on the
     * voice RMS drives a smoothed dB attenuation applied to music.
     */
    fun sidechainDuck(
        music: FloatArray, voice: FloatArray, sr: Int, ch: Int,
        thresholdDb: Double = -30.0, attenDb: Double = -10.0,
        attackMs: Double = 20.0, releaseMs: Double = 300.0,
    ) {
        if (music.isEmpty() || voice.isEmpty() || ch <= 0) return
        val frames = music.size / ch
        val voiceFrames = voice.size / ch
        val attackA = onePoleCoeff(attackMs, sr)
        val releaseA = onePoleCoeff(releaseMs, sr)
        var env = 0.0       // smoothed voice mean-square
        var gainDb = 0.0    // current music attenuation in dB
        val attenNeg = if (attenDb > 0.0) -attenDb else attenDb
        var f = 0
        while (f < frames) {
            // Voice RMS for this frame (average across channels).
            var sq = 0.0
            if (f < voiceFrames) {
                var c = 0
                val base = f * ch
                while (c < ch) { val v = voice[base + c].toDouble(); sq += v * v; c++ }
                sq /= ch
            }
            val a = if (sq > env) attackA else releaseA
            env = a * env + (1.0 - a) * sq
            val voiceDb = if (env > EPS) 10.0 * log10(env) else -120.0
            val targetDb = if (voiceDb > thresholdDb) attenNeg else 0.0
            val ga = if (targetDb < gainDb) attackA else releaseA
            gainDb = ga * gainDb + (1.0 - ga) * targetDb
            val lin = 10.0.pow(gainDb / 20.0).toFloat()
            val base = f * ch
            var c = 0
            while (c < ch) { music[base + c] = music[base + c] * lin; c++ }
            f++
        }
    }

    /** Linear-interp pan envelope across the buffer. `panEnv` pairs (timeMs, pan). */
    fun applyPanEnvelope(samples: FloatArray, sr: Int, ch: Int, panEnv: List<Pair<Double, Double>>) {
        if (samples.isEmpty() || ch != 2 || panEnv.isEmpty()) return
        val frames = samples.size / 2
        var idx = 0
        var f = 0
        while (f < frames) {
            val tMs = f * 1000.0 / sr
            val pan = lerpEnv(panEnv, tMs, idxHint = idx).also { idx = it.second }.first
            val (gl, gr) = constantPowerPan(pan)
            // Preserve mono-equivalent energy: average L+R, then re-pan.
            val l = samples[f * 2].toDouble()
            val r = samples[f * 2 + 1].toDouble()
            val mid = (l + r) * 0.5
            samples[f * 2] = (mid * gl * 2.0).toFloat()
            samples[f * 2 + 1] = (mid * gr * 2.0).toFloat()
            f++
        }
    }

    /** Fade-in over first `fadeInMs`, fade-out over last `fadeOutMs`. */
    fun applyFades(samples: FloatArray, sr: Int, ch: Int, fadeInMs: Double, fadeOutMs: Double, kind: String = "linear") {
        if (samples.isEmpty() || ch <= 0) return
        val frames = samples.size / ch
        val inFrames = (fadeInMs * sr / 1000.0).toInt().coerceIn(0, frames)
        val outFrames = (fadeOutMs * sr / 1000.0).toInt().coerceIn(0, frames)
        if (inFrames > 0) {
            var f = 0
            while (f < inFrames) {
                val g = fadeCurve(kind, f.toDouble() / inFrames).toFloat()
                val base = f * ch
                var c = 0
                while (c < ch) { samples[base + c] = samples[base + c] * g; c++ }
                f++
            }
        }
        if (outFrames > 0) {
            var f = 0
            while (f < outFrames) {
                val g = fadeCurve(kind, (outFrames - 1 - f).toDouble() / outFrames).toFloat()
                val frame = frames - outFrames + f
                val base = frame * ch
                var c = 0
                while (c < ch) { samples[base + c] = samples[base + c] * g; c++ }
                f++
            }
        }
    }

    // ---- Internals ---------------------------------------------------------

    private data class Biquad(val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double)

    /** RBJ low-shelf cookbook (S=1). */
    private fun lowShelf(sr: Int, f0: Double, gainDb: Double): Biquad {
        val A = 10.0.pow(gainDb / 40.0)
        val w0 = 2.0 * PI * f0 / sr
        val cosw = cos(w0); val sinw = sin(w0)
        val beta = 2.0 * sqrt(A) * (sinw / 2.0)
        val a0 = (A + 1.0) + (A - 1.0) * cosw + beta
        val b0 = A * ((A + 1.0) - (A - 1.0) * cosw + beta) / a0
        val b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosw) / a0
        val b2 = A * ((A + 1.0) - (A - 1.0) * cosw - beta) / a0
        val a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosw) / a0
        val a2 = ((A + 1.0) + (A - 1.0) * cosw - beta) / a0
        return Biquad(b0, b1, b2, a1, a2)
    }

    /** RBJ high-shelf cookbook (S=1). */
    private fun highShelf(sr: Int, f0: Double, gainDb: Double): Biquad {
        val A = 10.0.pow(gainDb / 40.0)
        val w0 = 2.0 * PI * f0 / sr
        val cosw = cos(w0); val sinw = sin(w0)
        val beta = 2.0 * sqrt(A) * (sinw / 2.0)
        val a0 = (A + 1.0) - (A - 1.0) * cosw + beta
        val b0 = A * ((A + 1.0) + (A - 1.0) * cosw + beta) / a0
        val b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw) / a0
        val b2 = A * ((A + 1.0) + (A - 1.0) * cosw - beta) / a0
        val a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosw) / a0
        val a2 = ((A + 1.0) - (A - 1.0) * cosw - beta) / a0
        return Biquad(b0, b1, b2, a1, a2)
    }

    /** RBJ peaking EQ cookbook. */
    private fun peaking(sr: Int, f0: Double, q: Double, gainDb: Double): Biquad {
        val A = 10.0.pow(gainDb / 40.0)
        val w0 = 2.0 * PI * f0 / sr
        val cosw = cos(w0); val sinw = sin(w0)
        val alpha = sinw / (2.0 * q)
        val a0 = 1.0 + alpha / A
        val b0 = (1.0 + alpha * A) / a0
        val b1 = -2.0 * cosw / a0
        val b2 = (1.0 - alpha * A) / a0
        val a1 = -2.0 * cosw / a0
        val a2 = (1.0 - alpha / A) / a0
        return Biquad(b0, b1, b2, a1, a2)
    }

    private fun applyBiquadInterleaved(samples: FloatArray, ch: Int, bq: Biquad) {
        // Direct-form I, per-channel state.
        val x1 = DoubleArray(ch); val x2 = DoubleArray(ch)
        val y1 = DoubleArray(ch); val y2 = DoubleArray(ch)
        val frames = samples.size / ch
        var f = 0
        while (f < frames) {
            val base = f * ch
            var c = 0
            while (c < ch) {
                val x0 = samples[base + c].toDouble()
                val y0 = bq.b0 * x0 + bq.b1 * x1[c] + bq.b2 * x2[c] - bq.a1 * y1[c] - bq.a2 * y2[c]
                x2[c] = x1[c]; x1[c] = x0
                y2[c] = y1[c]; y1[c] = y0
                val clipped = if (y0 > 1.0) 1.0 else if (y0 < -1.0) -1.0 else y0
                samples[base + c] = clipped.toFloat()
                c++
            }
            f++
        }
    }

    private fun onePoleCoeff(timeMs: Double, sr: Int): Double {
        if (timeMs <= 0.0) return 0.0
        // a = exp(-1 / (tau * sr)); tau in seconds.
        val tau = timeMs / 1000.0
        return exp(-1.0 / (tau * sr).coerceAtLeast(1.0))
    }

    private fun lerpEnv(env: List<Pair<Double, Double>>, tMs: Double, idxHint: Int): Pair<Double, Int> {
        if (env.size == 1) return env[0].second to 0
        if (tMs <= env.first().first) return env.first().second to 0
        if (tMs >= env.last().first) return env.last().second to env.size - 2
        var i = idxHint.coerceIn(0, env.size - 2)
        if (env[i].first > tMs) i = 0
        while (i < env.size - 1) {
            val a = env[i]; val b = env[i + 1]
            if (tMs >= a.first && tMs <= b.first) {
                val span = b.first - a.first
                if (span <= 0.0) return b.second to i
                val u = (tMs - a.first) / span
                return (a.second + (b.second - a.second) * u) to i
            }
            i++
        }
        return env.last().second to env.size - 2
    }

}
