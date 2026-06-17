package com.loopit.minis.audio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Pure-Kotlin WSOLA pitch-preserving time stretch. Frame 50 ms, hop 12.5 ms,
 * ±10 ms search window, Hann OLA. Pitch shift = WSOLA stretch + inverse
 * linear resample.
 */
object WsolaStretch {

    private const val FRAME_MS = 50.0
    private const val HOP_MS = 12.5
    private const val SEARCH_MS = 10.0

    fun stretch(samples: FloatArray, sr: Int, ch: Int, factor: Double): FloatArray {
        if (samples.isEmpty() || ch <= 0 || factor <= 0.0) return FloatArray(0)
        if (kotlin.math.abs(factor - 1.0) < 1e-4) return samples.copyOf()
        return if (ch == 1) wsolaMono(samples, sr, factor)
        else interleaveChannels(
            Array(ch) { c -> wsolaMono(extractChannel(samples, ch, c), sr, factor) },
            ch,
        )
    }

    fun pitchShift(samples: FloatArray, sr: Int, ch: Int, semitones: Double): FloatArray {
        if (samples.isEmpty() || ch <= 0) return FloatArray(0)
        if (kotlin.math.abs(semitones) < 1e-4) return samples.copyOf()
        // Stretch by 2^(s/12), then resample inverse to undo length change but keep pitch shift.
        val factor = 2.0.pow(semitones / 12.0)
        val stretched = stretch(samples, sr, ch, factor)
        return linearResample(stretched, ch, 1.0 / factor)
    }

    // ---- Core --------------------------------------------------------------

    private fun wsolaMono(src: FloatArray, sr: Int, factor: Double): FloatArray {
        val frameLen = max(8, (sr * FRAME_MS / 1000.0).toInt())
        val hop = max(2, (sr * HOP_MS / 1000.0).toInt())
        val search = max(1, (sr * SEARCH_MS / 1000.0).toInt())
        val win = hannWindow(frameLen)
        val outLen = (src.size / factor).toInt().coerceAtLeast(frameLen)
        val out = FloatArray(outLen + frameLen)

        // Analysis hop changes per output frame to achieve target speedup.
        val analysisHop = hop * factor
        val prev = FloatArray(frameLen) // last emitted (windowed) frame for similarity match
        var inPos = 0.0
        var outPos = 0
        var first = true
        while (true) {
            val nominal = inPos.roundToInt()
            val best: Int = if (first) {
                nominal
            } else {
                // Search ±`search` for window most similar to `prev`.
                val lo = max(0, nominal - search)
                val hi = min(src.size - frameLen, nominal + search)
                if (hi < lo) break
                bestSimilarityOffset(src, prev, frameLen, lo, hi)
            }
            if (best + frameLen > src.size) break
            // OLA the windowed source frame.
            var i = 0
            while (i < frameLen) {
                if (outPos + i < out.size) {
                    val w = win[i]
                    out[outPos + i] += src[best + i] * w
                }
                i++
            }
            // Capture last hop-overlap region for next correlation.
            i = 0
            while (i < frameLen) { prev[i] = src[best + i] * win[i]; i++ }
            outPos += hop
            if (outPos >= outLen) break
            inPos += analysisHop
            first = false
            if (inPos >= src.size - frameLen) break
        }
        // Compensate Hann OLA overlap gain (75% overlap with hop=frame/4 → ~1.5 amplitude).
        val gain = (hop.toDouble() / (frameLen / 2.0)).coerceIn(0.25, 4.0).toFloat()
        var i = 0
        while (i < outLen) { out[i] = out[i] * gain; i++ }
        return out.copyOf(outLen)
    }

    private fun bestSimilarityOffset(src: FloatArray, ref: FloatArray, n: Int, lo: Int, hi: Int): Int {
        var best = lo
        var bestScore = -Double.MAX_VALUE
        var off = lo
        while (off <= hi) {
            // Normalized cross-correlation between ref and src[off..off+n].
            var dot = 0.0
            var energy = 0.0
            var i = 0
            while (i < n) {
                val s = src[off + i].toDouble()
                dot += s * ref[i]
                energy += s * s
                i++
            }
            val score = dot / sqrt(energy + 1e-9)
            if (score > bestScore) { bestScore = score; best = off }
            off++
        }
        return best
    }

    private fun hannWindow(n: Int): FloatArray {
        val w = FloatArray(n)
        var i = 0
        while (i < n) {
            w[i] = (0.5 - 0.5 * cos(2.0 * PI * i / (n - 1).coerceAtLeast(1))).toFloat()
            i++
        }
        return w
    }

    private fun extractChannel(src: FloatArray, ch: Int, c: Int): FloatArray {
        val frames = src.size / ch
        val out = FloatArray(frames)
        var i = 0
        while (i < frames) { out[i] = src[i * ch + c]; i++ }
        return out
    }

    private fun interleaveChannels(per: Array<FloatArray>, ch: Int): FloatArray {
        val frames = per.minOf { it.size }
        val out = FloatArray(frames * ch)
        var f = 0
        while (f < frames) {
            var c = 0
            while (c < ch) { out[f * ch + c] = per[c][f]; c++ }
            f++
        }
        return out
    }

    private fun linearResample(src: FloatArray, ch: Int, factor: Double): FloatArray {
        if (src.isEmpty() || factor <= 0.0) return FloatArray(0)
        val srcFrames = src.size / ch
        val dstFrames = (srcFrames / factor).toInt().coerceAtLeast(1)
        val out = FloatArray(dstFrames * ch)
        var i = 0
        while (i < dstFrames) {
            val sp = i * factor
            val i0 = sp.toInt().coerceAtMost(srcFrames - 1)
            val i1 = (i0 + 1).coerceAtMost(srcFrames - 1)
            val frac = (sp - i0).toFloat()
            var c = 0
            while (c < ch) {
                val a = src[i0 * ch + c]
                val b = src[i1 * ch + c]
                out[i * ch + c] = a + (b - a) * frac
                c++
            }
            i++
        }
        return out
    }
}
