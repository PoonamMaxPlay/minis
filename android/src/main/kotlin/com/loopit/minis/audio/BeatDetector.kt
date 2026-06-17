package com.loopit.minis.audio

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Onset + BPM estimator. Hann-windowed STFT → spectral flux → adaptive
 * threshold peaks → autocorrelated inter-onset intervals for tempo.
 */
class BeatDetector {

    fun detect(path: String, result: MethodChannel.Result) {
        thread(name = "minis-beat-detect", isDaemon = true) {
            try {
                val dec = PcmDecoder.decode(path)
                val mono = downmix(dec.samples, dec.channels)
                val (onsetsMs, bpm) = analyze(mono, dec.sampleRate)
                postSuccess(result, mapOf(
                    "bpm" to bpm,
                    "onsetsMs" to onsetsMs,
                ))
            } catch (t: Throwable) {
                postError(result, "MINIS_BEATS", t.message ?: "beat detect failed")
            }
        }
    }

    private fun downmix(samples: FloatArray, ch: Int): FloatArray {
        if (ch <= 1) return samples
        val frames = samples.size / ch
        val out = FloatArray(frames)
        var f = 0
        while (f < frames) {
            var sum = 0.0f
            var c = 0
            while (c < ch) { sum += samples[f * ch + c]; c++ }
            out[f] = sum / ch
            f++
        }
        return out
    }

    private fun analyze(mono: FloatArray, sr: Int): Pair<List<Int>, Double> {
        val win = 1024
        val hop = 512
        if (mono.size < win) return emptyList<Int>() to 0.0

        val hann = FloatArray(win) { (0.5f - 0.5f * cos(2.0 * PI * it / (win - 1)).toFloat()) }
        val frames = (mono.size - win) / hop + 1
        val fluxRate = sr.toDouble() / hop.toDouble()

        // Precompute previous magnitude.
        val re = FloatArray(win)
        val im = FloatArray(win)
        var prevMag: FloatArray? = null
        val flux = FloatArray(frames)

        for (t in 0 until frames) {
            val off = t * hop
            for (i in 0 until win) {
                re[i] = mono[off + i] * hann[i]
                im[i] = 0.0f
            }
            fft(re, im)
            val half = win / 2
            val mag = FloatArray(half)
            for (k in 0 until half) {
                mag[k] = sqrt(re[k] * re[k] + im[k] * im[k])
            }
            if (prevMag != null) {
                var sum = 0.0f
                for (k in 0 until half) {
                    val d = mag[k] - prevMag!![k]
                    if (d > 0.0f) sum += d
                }
                flux[t] = sum
            }
            prevMag = mag
        }

        // Adaptive threshold: median over 0.5 s window × 1.5.
        val winMs = 500
        val winFrames = max(1, (fluxRate * winMs / 1000.0).roundToInt())
        val onsetTimesMs = ArrayList<Int>()
        val scratch = FloatArray(2 * winFrames + 1)
        var lastOnsetFrame = -1
        val minSepFrames = max(1, (fluxRate * 0.06).roundToInt()) // 60 ms refractory
        for (t in 0 until frames) {
            val lo = max(0, t - winFrames)
            val hi = (t + winFrames).coerceAtMost(frames - 1)
            val len = hi - lo + 1
            for (j in 0 until len) scratch[j] = flux[lo + j]
            val med = median(scratch, len)
            val thr = med * 1.5f
            if (flux[t] > thr && flux[t] > 1e-6f) {
                // Peak: greater than immediate neighbors.
                val left = if (t > 0) flux[t - 1] else 0.0f
                val right = if (t + 1 < frames) flux[t + 1] else 0.0f
                if (flux[t] >= left && flux[t] >= right && (lastOnsetFrame < 0 || t - lastOnsetFrame >= minSepFrames)) {
                    val ms = ((t * hop).toLong() * 1000L / sr).toInt()
                    onsetTimesMs.add(ms)
                    lastOnsetFrame = t
                }
            }
        }

        val rawBpm = estimateBpm(onsetTimesMs, fluxRate)
        val refined = if (rawBpm > 0.0) {
            val gridLen = (((onsetTimesMs.lastOrNull() ?: 0) * fluxRate / 1000.0).toInt() + 1).coerceAtLeast(8)
            val env = FloatArray(gridLen)
            for (ms in onsetTimesMs) {
                val idx = (ms * fluxRate / 1000.0).toInt().coerceIn(0, gridLen - 1)
                env[idx] = 1.0f
            }
            TempoRefiner.refine(rawBpm, env, fluxRate)
        } else 0.0
        return onsetTimesMs to refined
    }

    private fun estimateBpm(onsetsMs: List<Int>, fluxRate: Double): Double {
        if (onsetsMs.size < 4) return 0.0
        // Use IOI histogram autocorrelation across lag in [60..200] BPM.
        // Build onset envelope on a flux-rate grid.
        val maxMs = onsetsMs.last()
        val gridLen = max(8, (maxMs * fluxRate / 1000.0).toInt() + 1)
        val env = FloatArray(gridLen)
        for (ms in onsetsMs) {
            val idx = (ms * fluxRate / 1000.0).toInt().coerceIn(0, gridLen - 1)
            env[idx] = 1.0f
        }
        val minLag = (fluxRate * 60.0 / 200.0).toInt().coerceAtLeast(1) // 200 BPM
        val maxLag = (fluxRate * 60.0 / 60.0).toInt().coerceAtMost(gridLen - 1) // 60 BPM
        if (maxLag <= minLag) return 0.0
        var bestLag = minLag
        var bestVal = -1.0
        for (lag in minLag..maxLag) {
            var acc = 0.0
            var i = 0
            val n = gridLen - lag
            while (i < n) {
                acc += env[i] * env[i + lag]
                i++
            }
            if (acc > bestVal) { bestVal = acc; bestLag = lag }
        }
        return 60.0 * fluxRate / bestLag
    }

    private fun median(arr: FloatArray, len: Int): Float {
        // Copy + sort the live region.
        val copy = arr.copyOf(len)
        copy.sort()
        return if (len % 2 == 1) copy[len / 2]
        else 0.5f * (copy[len / 2 - 1] + copy[len / 2])
    }

    /**
     * In-place radix-2 Cooley-Tukey FFT. `re.size` must be a power of two.
     * No normalization; magnitudes only used relatively.
     */
    private fun fft(re: FloatArray, im: FloatArray) {
        val n = re.size
        if (n <= 1) return
        if (n and (n - 1) != 0) throw IllegalArgumentException("FFT size must be power of two")

        // Bit reversal.
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j or bit
            if (i < j) {
                var tmp = re[i]; re[i] = re[j]; re[j] = tmp
                tmp = im[i]; im[i] = im[j]; im[j] = tmp
            }
        }

        var len = 2
        while (len <= n) {
            val halfLen = len shr 1
            val angle = -2.0 * PI / len
            val wRe0 = cos(angle).toFloat()
            val wIm0 = kotlin.math.sin(angle).toFloat()
            var i = 0
            while (i < n) {
                var wr = 1.0f
                var wi = 0.0f
                var k = 0
                while (k < halfLen) {
                    val a = i + k
                    val b = i + k + halfLen
                    val tRe = re[b] * wr - im[b] * wi
                    val tIm = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tRe
                    im[b] = im[a] - tIm
                    re[a] = re[a] + tRe
                    im[a] = im[a] + tIm
                    val nwr = wr * wRe0 - wi * wIm0
                    val nwi = wr * wIm0 + wi * wRe0
                    wr = nwr; wi = nwi
                    k++
                }
                i += len
            }
            len = len shl 1
        }
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
