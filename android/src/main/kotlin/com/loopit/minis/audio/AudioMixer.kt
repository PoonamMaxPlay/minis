package com.loopit.minis.audio

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Multitrack PCM mix with optional LUFS normalization. Decodes each input via
 * `PcmDecoder`, upmixes mono → stereo, resamples (linear) to the first track's
 * rate, applies a piecewise-linear gain envelope, sums into a stereo output
 * buffer, clips, optionally normalizes, and encodes via `AacEncoder`.
 */
class AudioMixer {

    data class Track(
        val path: String,
        val inMs: Long = 0,
        val outMs: Long = 0,      // 0 = full length
        val positionMs: Long = 0, // offset in output timeline
        val gainEnv: List<Pair<Double, Double>> = emptyList(),
        val panEnv: List<Pair<Double, Double>> = emptyList(),
        val eqLowDb: Double = 0.0,
        val eqMidDb: Double = 0.0,
        val eqHighDb: Double = 0.0,
        val fadeInMs: Double = 0.0,
        val fadeOutMs: Double = 0.0,
        val fadeKind: String = "linear",
        val isVoiceForDuck: Boolean = false,
    )

    private val encoder = AacEncoder()
    private val normalizer = LufsNormalizer()

    fun mix(
        tracks: List<Track>,
        outPath: String,
        targetLufs: Double,
        result: MethodChannel.Result,
    ) {
        thread(name = "minis-audio-mix", isDaemon = true) {
            try {
                if (tracks.isEmpty()) throw IllegalArgumentException("tracks empty")
                val out = mixInternal(tracks, targetLufs)
                encoder.encode(out.samples, out.sampleRate, 2, outPath)
                postSuccess(result, mapOf(
                    "taskId" to UUID.randomUUID().toString(),
                    "path" to outPath,
                ))
            } catch (t: Throwable) {
                postError(result, "MINIS_MIX", t.message ?: "mix failed")
            }
        }
    }

    private data class MixOut(val samples: FloatArray, val sampleRate: Int)

    private fun mixInternal(tracks: List<Track>, targetLufs: Double): MixOut {
        val decoded = tracks.map { PcmDecoder.decode(it.path) }
        val targetSr = decoded.first().sampleRate

        // Convert each to stereo at targetSr. Apply in/out trim windows + EQ +
        // pan envelope + fades. Sidechain ducking applied at the end.
        data class Prepared(
            val samples: FloatArray,        // interleaved stereo at targetSr
            val positionFrames: Long,
            val gainEnv: List<Pair<Double, Double>>,
            val isVoice: Boolean,
        )

        val prepared = ArrayList<Prepared>(tracks.size)
        var totalOutFrames = 0L

        for (i in tracks.indices) {
            val t = tracks[i]
            val d = decoded[i]
            val resampled = resampleToStereo(d.samples, d.sampleRate, d.channels, targetSr)
            val totalFrames = resampled.size / 2
            val inFrame = (t.inMs * targetSr / 1000L).coerceIn(0L, totalFrames.toLong())
            val outFrameRaw = if (t.outMs <= 0L) totalFrames.toLong() else (t.outMs * targetSr / 1000L)
            val outFrame = outFrameRaw.coerceIn(inFrame, totalFrames.toLong())
            val sliceFrames = (outFrame - inFrame).toInt()
            if (sliceFrames <= 0) continue
            val slice = FloatArray(sliceFrames * 2)
            System.arraycopy(resampled, (inFrame * 2).toInt(), slice, 0, sliceFrames * 2)
            if (t.eqLowDb != 0.0 || t.eqMidDb != 0.0 || t.eqHighDb != 0.0) {
                MixerHelpers.applyEq(slice, targetSr, 2, t.eqLowDb, t.eqMidDb, t.eqHighDb)
            }
            if (t.panEnv.isNotEmpty()) {
                MixerHelpers.applyPanEnvelope(slice, targetSr, 2, t.panEnv)
            }
            if (t.fadeInMs > 0.0 || t.fadeOutMs > 0.0) {
                MixerHelpers.applyFades(slice, targetSr, 2, t.fadeInMs, t.fadeOutMs, t.fadeKind)
            }
            val posFrames = (t.positionMs * targetSr / 1000L).coerceAtLeast(0L)
            prepared.add(Prepared(slice, posFrames, t.gainEnv, t.isVoiceForDuck))
            val end = posFrames + sliceFrames
            if (end > totalOutFrames) totalOutFrames = end
        }

        if (totalOutFrames <= 0L) return MixOut(FloatArray(0), targetSr)

        val out = FloatArray((totalOutFrames * 2).toInt())
        val voiceBuf = FloatArray((totalOutFrames * 2).toInt())
        var anyVoice = false
        val musicAccum = FloatArray((totalOutFrames * 2).toInt())
        var anyMusic = false

        for (p in prepared) {
            val frames = p.samples.size / 2
            val basePos = p.positionFrames.toInt()
            val target = if (p.isVoice) voiceBuf else musicAccum
            if (p.isVoice) anyVoice = true else anyMusic = true
            var f = 0
            while (f < frames) {
                val tMs = (f.toDouble() / targetSr) * 1000.0
                val gain = envGain(p.gainEnv, tMs)
                val dstIdx = (basePos + f) * 2
                val srcIdx = f * 2
                target[dstIdx] += (p.samples[srcIdx] * gain).toFloat()
                target[dstIdx + 1] += (p.samples[srcIdx + 1] * gain).toFloat()
                f++
            }
        }

        if (anyVoice && anyMusic) {
            MixerHelpers.sidechainDuck(musicAccum, voiceBuf, targetSr, 2)
        }
        var k = 0
        while (k < out.size) {
            out[k] = musicAccum[k] + voiceBuf[k]
            k++
        }

        // Clip.
        var i = 0
        while (i < out.size) {
            val v = out[i]
            if (v > 1.0f) out[i] = 1.0f
            else if (v < -1.0f) out[i] = -1.0f
            i++
        }

        if (targetLufs != 0.0) {
            normalizer.normalizeInPlace(out, targetSr, 2, targetLufs)
        }

        return MixOut(out, targetSr)
    }

    private fun envGain(env: List<Pair<Double, Double>>, tMs: Double): Double {
        if (env.isEmpty()) return 1.0
        if (env.size == 1) return env[0].second
        if (tMs <= env.first().first) return env.first().second
        if (tMs >= env.last().first) return env.last().second
        // Linear search is fine for small envelopes; binary search if perf
        // ever bites. // TODO(improvement4.md D7) bsearch when env.size > 32
        var i = 0
        while (i < env.size - 1) {
            val a = env[i]
            val b = env[i + 1]
            if (tMs >= a.first && tMs <= b.first) {
                val span = b.first - a.first
                if (span <= 0.0) return b.second
                val t = (tMs - a.first) / span
                return a.second + (b.second - a.second) * t
            }
            i++
        }
        return env.last().second
    }

    private fun resampleToStereo(src: FloatArray, srcSr: Int, srcCh: Int, dstSr: Int): FloatArray {
        // First upmix to stereo at srcSr.
        val stereo = if (srcCh == 2) src else upmixMonoToStereo(src)
        if (srcSr == dstSr) return stereo
        val srcFrames = stereo.size / 2
        if (srcFrames == 0) return FloatArray(0)
        val dstFrames = ((srcFrames.toLong() * dstSr.toLong()) / srcSr.toLong()).toInt()
        val out = FloatArray(dstFrames * 2)
        val ratio = srcSr.toDouble() / dstSr.toDouble()
        var i = 0
        while (i < dstFrames) {
            val srcPos = i * ratio
            val i0 = srcPos.toInt().coerceAtMost(srcFrames - 1)
            val i1 = (i0 + 1).coerceAtMost(srcFrames - 1)
            val frac = (srcPos - i0).toFloat()
            val l0 = stereo[i0 * 2]
            val r0 = stereo[i0 * 2 + 1]
            val l1 = stereo[i1 * 2]
            val r1 = stereo[i1 * 2 + 1]
            out[i * 2] = l0 + (l1 - l0) * frac
            out[i * 2 + 1] = r0 + (r1 - r0) * frac
            i++
        }
        return out
    }

    private fun upmixMonoToStereo(mono: FloatArray): FloatArray {
        val out = FloatArray(mono.size * 2)
        var i = 0
        while (i < mono.size) {
            val v = mono[i]
            out[i * 2] = v
            out[i * 2 + 1] = v
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
