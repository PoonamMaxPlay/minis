package com.loopit.minis.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import kotlin.concurrent.thread
import kotlin.math.max

/**
 * Container-boundary trim for MP4/M4A/AAC sources. Copies compressed samples
 * via MediaExtractor → MediaMuxer between `inMs` and `outMs`. No re-encode.
 *
 * Sample-accurate (sub-frame) trim requires PCM decode + re-encode (FFmpeg
 * `swr_convert`) — deferred to vendored-FFmpeg phase. Until then, cut snaps
 * to the nearest sync sample after `inMs` and the last sample before `outMs`.
 */
class AudioTrimmer {
    fun trim(
        path: String,
        inMs: Long,
        outMs: Long,
        outPath: String,
        mode: String,
        result: MethodChannel.Result,
    ) {
        thread(name = "minis-audio-trim", isDaemon = true) {
            try {
                if (mode == "accurate") {
                    runAccurate(path, inMs, outMs, outPath)
                } else {
                    run(path, inMs, outMs, outPath)
                }
                result.success(mapOf("path" to outPath))
            } catch (t: Throwable) {
                result.error("MINIS_AUDIO_TRIM", t.message, null)
            }
        }
    }

    private fun runAccurate(path: String, inMs: Long, outMs: Long, outPath: String) {
        if (outMs <= inMs) throw IllegalArgumentException("outMs<=inMs")
        File(outPath).parentFile?.mkdirs()
        val pcm = PcmDecoder.decode(path)
        val sr = pcm.sampleRate
        val ch = pcm.channels
        val inSample = (inMs * sr / 1000L).coerceAtLeast(0L).toInt()
        val outSample = (outMs * sr / 1000L).coerceAtMost((pcm.samples.size / ch).toLong()).toInt()
        if (outSample <= inSample) throw IllegalArgumentException("trim window outside source")
        val frames = outSample - inSample
        val slice = FloatArray(frames * ch)
        System.arraycopy(pcm.samples, inSample * ch, slice, 0, frames * ch)
        AacEncoder().encode(slice, sr, ch, outPath)
    }

    private fun run(path: String, inMs: Long, outMs: Long, outPath: String) {
        if (outMs <= inMs) throw IllegalArgumentException("outMs<=inMs")
        File(outPath).parentFile?.mkdirs()
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
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
            if (audioTrack < 0 || format == null) throw IllegalStateException("no audio track in $path")
            extractor.selectTrack(audioTrack)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val container = when {
                mime.contains("opus") || mime.contains("vorbis") -> MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
                else -> MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            }
            muxer = MediaMuxer(outPath, container)
            val outTrack = muxer.addTrack(format)
            muxer.start()

            val maxBuf = max(
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))
                    format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 1 shl 16,
                1 shl 16,
            )
            val buf = ByteBuffer.allocate(maxBuf)
            extractor.seekTo(inMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val info = MediaCodec.BufferInfo()
            val outUs = outMs * 1000L
            var baseUs = -1L
            while (true) {
                buf.clear()
                val size = extractor.readSampleData(buf, 0)
                if (size <= 0) break
                val pts = extractor.sampleTime
                if (pts >= outUs) break
                if (pts < inMs * 1000L) {
                    extractor.advance(); continue
                }
                if (baseUs < 0) baseUs = pts
                info.offset = 0
                info.size = size
                info.presentationTimeUs = pts - baseUs
                info.flags = extractor.sampleFlags
                try {
                    muxer.writeSampleData(outTrack, buf, info)
                } catch (_: Throwable) { /* skip bad sample */ }
                extractor.advance()
            }
        } finally {
            try { muxer?.stop() } catch (_: Throwable) {}
            try { muxer?.release() } catch (_: Throwable) {}
            try { extractor.release() } catch (_: Throwable) {}
        }
    }
}
