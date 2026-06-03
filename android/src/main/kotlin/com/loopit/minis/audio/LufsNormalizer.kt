package com.loopit.minis.audio

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sin

/**
 * ITU-R BS.1770-4 integrated loudness measurement + scalar gain. Pure Kotlin
 * biquad K-weighting; assumes ≤ 2 channels (stereo coefficients 1.0/1.0).
 */
class LufsNormalizer {

    private val encoder = AacEncoder()

    fun normalize(path: String, outPath: String, targetLufs: Double, result: MethodChannel.Result) {
        thread(name = "minis-lufs-normalize", isDaemon = true) {
            try {
                val dec = PcmDecoder.decode(path)
                val measured = normalizeInPlace(dec.samples, dec.sampleRate, dec.channels, targetLufs)
                encoder.encode(dec.samples, dec.sampleRate, dec.channels, outPath)
                postSuccess(result, mapOf("path" to outPath, "inputLufs" to measured, "targetLufs" to targetLufs))
            } catch (t: Throwable) {
                postError(result, "MINIS_LUFS", t.message ?: "lufs failed")
            }
        }
    }

    /**
     * Measures integrated LUFS of an interleaved PCM buffer (samples in [-1,1]).
     */
    fun measureLufs(samples: FloatArray, sr: Int, ch: Int): Double {
        if (samples.isEmpty() || ch <= 0) return -70.0
        val filtered = applyKWeighting(samples, sr, ch)
        return integratedLoudness(filtered, sr, ch)
    }

    /**
     * Scales `samples` in place to reach `targetLufs`. Returns the measured
     * input LUFS.
     */
    fun normalizeInPlace(samples: FloatArray, sr: Int, ch: Int, targetLufs: Double): Double {
        val measured = measureLufs(samples, sr, ch)
        if (!measured.isFinite() || measured <= -70.0) return measured
        val gain = 10.0.pow((targetLufs - measured) / 20.0).toFloat()
        var i = 0
        while (i < samples.size) {
            val v = samples[i] * gain
            samples[i] = if (v > 1.0f) 1.0f else if (v < -1.0f) -1.0f else v
            i++
        }
        return measured
    }

    // ---- K-weighting (RBJ biquad) ----------------------------------------

    private data class Biquad(val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double)

    private fun preFilter(sr: Int): Biquad {
        // High-shelf @ 1681 Hz, +4 dB (BS.1770 stage 1).
        val f0 = 1681.974450955533
        val g = 3.999843853973347
        val q = 0.7071752369554196
        val k = kotlin.math.tan(PI * f0 / sr)
        val vh = 10.0.pow(g / 20.0)
        val vb = vh.pow(0.4996667741545416)
        val a0 = 1.0 + k / q + k * k
        val b0 = (vh + vb * k / q + k * k) / a0
        val b1 = 2.0 * (k * k - vh) / a0
        val b2 = (vh - vb * k / q + k * k) / a0
        val a1 = 2.0 * (k * k - 1.0) / a0
        val a2 = (1.0 - k / q + k * k) / a0
        return Biquad(b0, b1, b2, a1, a2)
    }

    private fun rlbFilter(sr: Int): Biquad {
        // High-pass @ ~38 Hz, Q=0.5 (BS.1770 stage 2 / RLB).
        val f0 = 38.13547087602444
        val q = 0.5003270373238773
        val w0 = 2.0 * PI * f0 / sr
        val cosw = cos(w0)
        val sinw = sin(w0)
        val alpha = sinw / (2.0 * q)
        val a0 = 1.0 + alpha
        val b0 = (1.0 + cosw) / 2.0 / a0
        val b1 = -(1.0 + cosw) / a0
        val b2 = (1.0 + cosw) / 2.0 / a0
        val a1 = -2.0 * cosw / a0
        val a2 = (1.0 - alpha) / a0
        return Biquad(b0, b1, b2, a1, a2)
    }

    private fun applyKWeighting(samples: FloatArray, sr: Int, ch: Int): FloatArray {
        val out = FloatArray(samples.size)
        val pre = preFilter(sr)
        val rlb = rlbFilter(sr)
        for (c in 0 until ch) {
            var x1 = 0.0; var x2 = 0.0; var y1 = 0.0; var y2 = 0.0
            var u1 = 0.0; var u2 = 0.0; var v1 = 0.0; var v2 = 0.0
            var i = c
            while (i < samples.size) {
                val x0 = samples[i].toDouble()
                val y0 = pre.b0 * x0 + pre.b1 * x1 + pre.b2 * x2 - pre.a1 * y1 - pre.a2 * y2
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
                val v0 = rlb.b0 * y0 + rlb.b1 * u1 + rlb.b2 * u2 - rlb.a1 * v1 - rlb.a2 * v2
                u2 = u1; u1 = y0; v2 = v1; v1 = v0
                out[i] = v0.toFloat()
                i += ch
            }
        }
        return out
    }

    private fun integratedLoudness(filtered: FloatArray, sr: Int, ch: Int): Double {
        val frames = filtered.size / ch
        if (frames == 0) return -70.0
        val blockFrames = (0.4 * sr).toInt().coerceAtLeast(1)
        val stepFrames = (0.1 * sr).toInt().coerceAtLeast(1)
        if (frames < blockFrames) return -70.0

        // Channel weights: BS.1770 stereo = L:1, R:1.
        val wts = DoubleArray(ch) { 1.0 }

        val nBlocks = (frames - blockFrames) / stepFrames + 1
        val blockLoudness = DoubleArray(nBlocks)
        val blockMeanSq = DoubleArray(nBlocks)

        for (b in 0 until nBlocks) {
            val start = b * stepFrames
            var weightedSum = 0.0
            for (c in 0 until ch) {
                var sq = 0.0
                var idx = (start * ch) + c
                var f = 0
                while (f < blockFrames) {
                    val v = filtered[idx].toDouble()
                    sq += v * v
                    idx += ch
                    f++
                }
                weightedSum += wts[c] * (sq / blockFrames)
            }
            blockMeanSq[b] = weightedSum
            blockLoudness[b] = if (weightedSum > 0.0) -0.691 + 10.0 * log10(weightedSum) else Double.NEGATIVE_INFINITY
        }

        // Absolute gate at -70 LUFS.
        var sumAbs = 0.0
        var countAbs = 0
        for (b in 0 until nBlocks) {
            if (blockLoudness[b] > -70.0) {
                sumAbs += blockMeanSq[b]
                countAbs++
            }
        }
        if (countAbs == 0) return -70.0
        val meanAbs = sumAbs / countAbs
        val absLufs = -0.691 + 10.0 * log10(meanAbs.coerceAtLeast(1e-30))
        val relGate = absLufs - 10.0

        var sumRel = 0.0
        var countRel = 0
        for (b in 0 until nBlocks) {
            if (blockLoudness[b] > -70.0 && blockLoudness[b] > relGate) {
                sumRel += blockMeanSq[b]
                countRel++
            }
        }
        if (countRel == 0) return absLufs
        val meanRel = sumRel / countRel
        return -0.691 + 10.0 * log10(meanRel.coerceAtLeast(1e-30))
    }

    private fun postSuccess(result: MethodChannel.Result, payload: Map<String, Any?>) {
        Handler(Looper.getMainLooper()).post {
            try { result.success(payload) } catch (_: Throwable) {}
        }
    }

    private fun postError(result: MethodChannel.Result, code: String, msg: String) {
        Handler(Looper.getMainLooper()).post {
            try { result.error(code, msg, null) } catch (_: Throwable) {}
        }
    }
}

