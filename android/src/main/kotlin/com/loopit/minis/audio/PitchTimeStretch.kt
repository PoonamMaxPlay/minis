package com.loopit.minis.audio

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Time/pitch operations. Android has no quality SOLA/PSOLA platform API; we
 * implement only the linear-interpolation resample path here. Pitch-preserving
 * stretch and isolated pitch shift require a vendored SoundTouch/RubberBand
 * (deferred — improvement4.md D9).
 */
class PitchTimeStretch {

    private val encoder = AacEncoder()

    fun timeStretch(
        path: String,
        factor: Double,
        keepPitch: Boolean,
        outPath: String,
        result: MethodChannel.Result,
    ) {
        thread(name = "minis-time-stretch", isDaemon = true) {
            try {
                if (factor <= 0.0) throw IllegalArgumentException("factor must be > 0")
                val dec = PcmDecoder.decode(path)
                val out = if (keepPitch) {
                    WsolaStretch.stretch(dec.samples, dec.sampleRate, dec.channels, factor)
                } else {
                    linearResampleInterleaved(dec.samples, dec.channels, factor)
                }
                encoder.encode(out, dec.sampleRate, dec.channels, outPath)
                postSuccess(result, mapOf("path" to outPath))
            } catch (t: Throwable) {
                postError(result, "MINIS_TIME_STRETCH", t.message ?: "time stretch failed")
            }
        }
    }

    fun pitchShift(
        path: String,
        semitones: Double,
        outPath: String,
        result: MethodChannel.Result,
    ) {
        thread(name = "minis-pitch-shift", isDaemon = true) {
            try {
                val dec = PcmDecoder.decode(path)
                val out = WsolaStretch.pitchShift(dec.samples, dec.sampleRate, dec.channels, semitones)
                encoder.encode(out, dec.sampleRate, dec.channels, outPath)
                postSuccess(result, mapOf("path" to outPath))
            } catch (t: Throwable) {
                postError(result, "MINIS_PITCH_SHIFT", t.message ?: "pitch shift failed")
            }
        }
    }

    /**
     * Speed-up `factor>1` shortens output; `factor<1` lengthens. Pitch shifts
     * inversely because we resample without overlap-add.
     */
    private fun linearResampleInterleaved(src: FloatArray, ch: Int, factor: Double): FloatArray {
        val srcFrames = src.size / ch
        if (srcFrames == 0) return FloatArray(0)
        val dstFrames = (srcFrames / factor).toInt().coerceAtLeast(1)
        val out = FloatArray(dstFrames * ch)
        var i = 0
        while (i < dstFrames) {
            val srcPos = i * factor
            val i0 = srcPos.toInt().coerceAtMost(srcFrames - 1)
            val i1 = (i0 + 1).coerceAtMost(srcFrames - 1)
            val frac = (srcPos - i0).toFloat()
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
