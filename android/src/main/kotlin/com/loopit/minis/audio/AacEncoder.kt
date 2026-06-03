package com.loopit.minis.audio

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Encodes a stereo/mono `FloatArray` of interleaved PCM to an .m4a AAC-LC
 * container via `MediaCodec("audio/mp4a-latm")` + `MediaMuxer`. Defaults to
 * 128 kbps.
 */
class AacEncoder {

    fun encode(samples: FloatArray, sr: Int, ch: Int, outPath: String, bitRate: Int = 128_000) {
        require(ch in 1..2) { "ch must be 1 or 2, got $ch" }
        File(outPath).parentFile?.mkdirs()

        val mime = MediaFormat.MIMETYPE_AUDIO_AAC
        val format = MediaFormat.createAudioFormat(mime, sr, ch).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }

        val codec = MediaCodec.createEncoderByType(mime)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        val muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var trackIdx = -1
        var muxerStarted = false

        val frames = samples.size / ch
        val info = MediaCodec.BufferInfo()
        val bytesPerFrame = 2 * ch
        // 1024 frames per AAC-LC granule keeps encoder happy.
        val granule = 1024
        var sampleIdx = 0
        var presentationUs = 0L
        var inputDone = false
        var eos = false

        try {
            while (!eos) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        buf.clear()
                        val framesThis = minOf(granule, frames - sampleIdx)
                        if (framesThis <= 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, presentationUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val bytes = framesThis * bytesPerFrame
                            val shortBuf = buf.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                            val srcOff = sampleIdx * ch
                            var i = 0
                            while (i < framesThis * ch) {
                                val v = (samples[srcOff + i] * 32767.0f).toInt().coerceIn(-32768, 32767)
                                shortBuf.put(i, v.toShort())
                                i++
                            }
                            codec.queueInputBuffer(inIdx, 0, bytes, presentationUs, 0)
                            presentationUs += framesThis.toLong() * 1_000_000L / sr.toLong()
                            sampleIdx += framesThis
                        }
                    }
                }

                var outIdx = codec.dequeueOutputBuffer(info, 10_000)
                while (outIdx >= 0 || outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        if (muxerStarted) throw IllegalStateException("format changed twice")
                        trackIdx = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        muxerStarted = true
                    } else if (outIdx >= 0) {
                        val out = codec.getOutputBuffer(outIdx)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            info.size = 0
                        }
                        if (info.size > 0 && muxerStarted) {
                            out.position(info.offset)
                            out.limit(info.offset + info.size)
                            muxer.writeSampleData(trackIdx, out, info)
                        }
                        codec.releaseOutputBuffer(outIdx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            eos = true
                            break
                        }
                    }
                    outIdx = codec.dequeueOutputBuffer(info, 0)
                }
            }
        } finally {
            try { codec.stop() } catch (_: Throwable) {}
            try { codec.release() } catch (_: Throwable) {}
            try { if (muxerStarted) muxer.stop() } catch (_: Throwable) {}
            try { muxer.release() } catch (_: Throwable) {}
        }
    }
}
