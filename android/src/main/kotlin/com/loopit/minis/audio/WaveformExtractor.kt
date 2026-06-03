package com.loopit.minis.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt
import kotlin.concurrent.thread

/**
 * Decodes any platform-supported audio file via MediaExtractor + MediaCodec,
 * downsamples PCM into N peak/RMS pairs. Pure Kotlin — no native deps.
 */
class WaveformExtractor(@Suppress("UNUSED_PARAMETER") context: Context) {

    fun extract(path: String, peakCount: Int, result: MethodChannel.Result) {
        thread(name = "minis-waveform", isDaemon = true) {
            try {
                val data = decodeAndDownsample(path, peakCount.coerceAtLeast(1))
                postSuccess(result, data)
            } catch (t: Throwable) {
                postError(result, t)
            }
        }
    }

    private data class Output(
        val peaks: DoubleArray,
        val rms: DoubleArray,
        val durationMs: Long,
    )

    private fun decodeAndDownsample(path: String, peakCount: Int): Output {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        var audioTrack = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
                audioTrack = i
                format = f
                break
            }
        }
        if (audioTrack < 0 || format == null) {
            extractor.release()
            throw IllegalStateException("No audio track in $path")
        }
        extractor.selectTrack(audioTrack)

        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val durationUs =
            if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
        val channels =
            if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 1

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()

        // Reservoir of absolute samples. For very long clips this would blow
        // memory; bucketed approximation keeps it bounded.
        val maxBucketSamples = max(8L, durationUs / 1000L)
        val targetTotal = max(peakCount * 256L, maxBucketSamples)
        val downsample = DownsampleBucket(peakCount)

        val info = MediaCodec.BufferInfo()
        var eos = false

        while (!eos) {
            val inIdx = codec.dequeueInputBuffer(10_000)
            if (inIdx >= 0) {
                val buf = codec.getInputBuffer(inIdx)!!
                val size = extractor.readSampleData(buf, 0)
                if (size < 0) {
                    codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                } else {
                    codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                    extractor.advance()
                }
            }

            var outIdx = codec.dequeueOutputBuffer(info, 10_000)
            while (outIdx >= 0) {
                val out = codec.getOutputBuffer(outIdx)!!
                out.position(info.offset)
                out.limit(info.offset + info.size)
                downsample.feed(out, channels)
                codec.releaseOutputBuffer(outIdx, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                    eos = true
                }
                outIdx = codec.dequeueOutputBuffer(info, 0)
            }
        }

        try { codec.stop() } catch (_: Throwable) {}
        try { codec.release() } catch (_: Throwable) {}
        try { extractor.release() } catch (_: Throwable) {}

        val (peaks, rms) = downsample.finish()
        // discourage hint about unused
        @Suppress("UNUSED_VARIABLE") val unused = targetTotal
        return Output(peaks, rms, durationUs / 1000L)
    }

    /**
     * Online bucketing: pushes incoming 16-bit PCM (mono-folded) into a fixed
     * number of buckets, growing each bucket's count as samples arrive. Output
     * is normalized to [0,1] peaks + RMS.
     */
    private class DownsampleBucket(val peakCount: Int) {
        private val peaks = DoubleArray(peakCount)
        private val sumSq = DoubleArray(peakCount)
        private val counts = LongArray(peakCount)
        private var samplesSeen = 0L
        private var bucketSize: Long = 1L
        private var cursor = 0

        fun feed(buf: ByteBuffer, channels: Int) {
            val raw = buf.order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            val limit = raw.limit()
            var i = 0
            while (i < limit) {
                var sum = 0L
                var c = 0
                while (c < channels && i < limit) {
                    sum += raw.get(i)
                    i++
                    c++
                }
                val sample = if (channels == 0) 0L else sum / channels
                val norm = sample / 32768.0
                val absVal = abs(norm)
                push(absVal, norm)
            }
        }

        private fun push(absVal: Double, signed: Double) {
            samplesSeen++
            growIfNeeded()
            val idx = cursor.coerceAtMost(peakCount - 1)
            if (absVal > peaks[idx]) peaks[idx] = absVal
            sumSq[idx] += signed * signed
            counts[idx]++
            if (counts[idx] >= bucketSize) {
                cursor = (cursor + 1).coerceAtMost(peakCount - 1)
            }
        }

        private fun growIfNeeded() {
            // Once we've overflowed last bucket, halve the data: merge pairs of
            // buckets and double bucketSize. Keeps output count fixed.
            if (cursor >= peakCount - 1 && counts[peakCount - 1] >= bucketSize) {
                var w = 0
                var r = 0
                while (r + 1 < peakCount) {
                    peaks[w] = max(peaks[r], peaks[r + 1])
                    sumSq[w] = sumSq[r] + sumSq[r + 1]
                    counts[w] = counts[r] + counts[r + 1]
                    w++
                    r += 2
                }
                if (r < peakCount) {
                    peaks[w] = peaks[r]
                    sumSq[w] = sumSq[r]
                    counts[w] = counts[r]
                    w++
                }
                for (i in w until peakCount) {
                    peaks[i] = 0.0
                    sumSq[i] = 0.0
                    counts[i] = 0L
                }
                cursor = w
                bucketSize *= 2L
            }
        }

        fun finish(): Pair<DoubleArray, DoubleArray> {
            val r = DoubleArray(peakCount)
            for (i in 0 until peakCount) {
                r[i] = if (counts[i] > 0) sqrt(sumSq[i] / counts[i]) else 0.0
            }
            return peaks to r
        }
    }

    private fun postSuccess(result: MethodChannel.Result, out: Output) {
        Handler(Looper.getMainLooper()).post {
            result.success(
                mapOf(
                    "peaks" to out.peaks.toList(),
                    "rms" to out.rms.toList(),
                    "durationMs" to out.durationMs.toInt(),
                )
            )
        }
    }

    private fun postError(result: MethodChannel.Result, t: Throwable) {
        Handler(Looper.getMainLooper()).post {
            result.error("MINIS_WAVEFORM", t.message, null)
        }
    }
}
