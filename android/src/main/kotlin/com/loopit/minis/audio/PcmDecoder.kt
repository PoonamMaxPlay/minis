package com.loopit.minis.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteOrder

/**
 * Decodes any platform-supported audio source into a flat `FloatArray` of
 * interleaved PCM at the source rate/channel layout, normalized to [-1,1].
 * Caller is responsible for upmixing mono → stereo and resampling.
 */
object PcmDecoder {

    data class Result(
        val samples: FloatArray,
        val sampleRate: Int,
        val channels: Int,
    )

    fun decode(path: String): Result {
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
        val sampleRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE))
            format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
        val channels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
            format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 1

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()

        val info = MediaCodec.BufferInfo()
        var eos = false
        var inputDone = false
        val out = FloatArrayList(sampleRate * channels)

        while (!eos) {
            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val buf = codec.getInputBuffer(inIdx)!!
                    val size = extractor.readSampleData(buf, 0)
                    if (size < 0) {
                        codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            var outIdx = codec.dequeueOutputBuffer(info, 10_000)
            while (outIdx >= 0) {
                val buf = codec.getOutputBuffer(outIdx)!!
                buf.position(info.offset)
                buf.limit(info.offset + info.size)
                val shorts = buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                val n = shorts.remaining()
                out.ensureCapacity(out.size + n)
                var i = 0
                while (i < n) {
                    out.add(shorts.get(i) / 32768.0f)
                    i++
                }
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

        return Result(out.toArray(), sampleRate, channels)
    }

    private class FloatArrayList(initial: Int = 1024) {
        private var buf: FloatArray = FloatArray(maxOf(initial, 16))
        var size: Int = 0
            private set

        fun add(v: Float) {
            if (size == buf.size) grow(size + 1)
            buf[size++] = v
        }

        fun ensureCapacity(min: Int) {
            if (min > buf.size) grow(min)
        }

        private fun grow(min: Int) {
            var cap = buf.size
            while (cap < min) cap = (cap * 2).coerceAtLeast(min)
            buf = buf.copyOf(cap)
        }

        fun toArray(): FloatArray = buf.copyOf(size)
    }
}
