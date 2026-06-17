package com.loopit.minis.audio

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * AudioRecord PCM → MediaCodec("audio/opus") → MediaMuxer(MUXER_OUTPUT_OGG).
 * Requires API 29+ because Ogg muxing landed in API 29 and platform Opus
 * encoder appeared in API 29.
 */
@TargetApi(Build.VERSION_CODES.Q)
class OpusRecorder {
    private var record: AudioRecord? = null
    private var codec: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var trackIdx: Int = -1
    private var muxerStarted: Boolean = false
    private var thread: Thread? = null
    private var path: String = ""
    private var sampleRate: Int = 48_000
    private var channels: Int = 1
    @Volatile private var paused: Boolean = false
    @Volatile private var stopRequested: Boolean = false
    private var startedAt: Long = 0
    private var accumulated: Long = 0
    private var presentationUs: Long = 0
    private var levelSink: EventChannel.EventSink? = null
    private var lastLevelPostMs: Long = 0

    fun attachLevelSink(s: EventChannel.EventSink?) {
        levelSink = s
    }

    fun isActive(): Boolean = record != null

    @SuppressLint("MissingPermission")
    fun start(path: String, sampleRate: Int, channels: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("Opus output requires API 29+")
        }
        stopSilently()
        this.path = path
        this.sampleRate = sampleRate
        this.channels = channels.coerceIn(1, 2)

        File(path).parentFile?.mkdirs()

        val channelCfg = if (this.channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelCfg, encoding)
        if (minBuf <= 0) throw IllegalStateException("AudioRecord.getMinBufferSize=$minBuf")
        val bufSize = max(minBuf, sampleRate * this.channels * 2 / 10)
        val ar = AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, channelCfg, encoding, bufSize)
        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            ar.release()
            throw IllegalStateException("AudioRecord init failed")
        }

        val mime = MediaFormat.MIMETYPE_AUDIO_OPUS
        val format = MediaFormat.createAudioFormat(mime, sampleRate, this.channels).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, 64_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufSize)
        }
        val enc = MediaCodec.createEncoderByType(mime)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        enc.start()

        val mux = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_OGG)

        record = ar
        codec = enc
        muxer = mux
        trackIdx = -1
        muxerStarted = false
        paused = false
        stopRequested = false
        startedAt = SystemClock.elapsedRealtime()
        accumulated = 0
        presentationUs = 0
        ar.startRecording()
        thread = Thread({ pump(ar, enc, mux, bufSize) }, "minis-opus-rec").apply {
            isDaemon = true
            start()
        }
    }

    fun pause() {
        if (paused) return
        accumulated += SystemClock.elapsedRealtime() - startedAt
        paused = true
    }

    fun resume() {
        if (!paused) return
        startedAt = SystemClock.elapsedRealtime()
        paused = false
    }

    fun stop(): Map<String, Any> {
        if (record == null) return mapOf("path" to path, "durationMs" to 0)
        stopRequested = true
        try { thread?.join(800) } catch (_: Throwable) {}
        thread = null
        val ar = record; record = null
        try { ar?.stop() } catch (_: Throwable) {}
        try { ar?.release() } catch (_: Throwable) {}
        val c = codec; codec = null
        try { c?.stop() } catch (_: Throwable) {}
        try { c?.release() } catch (_: Throwable) {}
        val m = muxer; muxer = null
        try { if (muxerStarted) m?.stop() } catch (_: Throwable) {}
        try { m?.release() } catch (_: Throwable) {}
        val now = SystemClock.elapsedRealtime()
        val dur = (accumulated + if (paused) 0L else (now - startedAt)).coerceAtLeast(0)
        return mapOf("path" to path, "durationMs" to dur.toInt())
    }

    fun dispose() {
        stopSilently()
        levelSink = null
    }

    private fun stopSilently() {
        if (record == null) return
        stopRequested = true
        try { thread?.join(300) } catch (_: Throwable) {}
        thread = null
        try { record?.stop() } catch (_: Throwable) {}
        try { record?.release() } catch (_: Throwable) {}
        record = null
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        codec = null
        try { if (muxerStarted) muxer?.stop() } catch (_: Throwable) {}
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null
        muxerStarted = false
    }

    private fun pump(ar: AudioRecord, enc: MediaCodec, mux: MediaMuxer, bufSize: Int) {
        val pcm = ByteArray(bufSize)
        val info = MediaCodec.BufferInfo()
        var inputEos = false
        while (!stopRequested || !inputEos) {
            if (paused) {
                try { Thread.sleep(10) } catch (_: InterruptedException) {}
                continue
            }
            if (!inputEos) {
                val inIdx = enc.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val buf = enc.getInputBuffer(inIdx)!!
                    buf.clear()
                    val n = try { ar.read(pcm, 0, pcm.size) } catch (_: Throwable) { -1 }
                    if (stopRequested && (n <= 0)) {
                        enc.queueInputBuffer(inIdx, 0, 0, presentationUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputEos = true
                    } else if (n > 0) {
                        buf.put(pcm, 0, n)
                        enc.queueInputBuffer(inIdx, 0, n, presentationUs, 0)
                        val frames = n / (2 * channels)
                        presentationUs += frames.toLong() * 1_000_000L / sampleRate.toLong()
                        postLevels(pcm, n)
                    } else if (stopRequested) {
                        enc.queueInputBuffer(inIdx, 0, 0, presentationUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputEos = true
                    } else {
                        enc.queueInputBuffer(inIdx, 0, 0, presentationUs, 0)
                    }
                }
            }
            var outIdx = enc.dequeueOutputBuffer(info, 10_000)
            while (outIdx >= 0 || outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    if (!muxerStarted) {
                        trackIdx = mux.addTrack(enc.outputFormat)
                        mux.start()
                        muxerStarted = true
                    }
                } else if (outIdx >= 0) {
                    val out = enc.getOutputBuffer(outIdx)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        info.size = 0
                    }
                    if (info.size > 0 && muxerStarted) {
                        out.position(info.offset)
                        out.limit(info.offset + info.size)
                        try { mux.writeSampleData(trackIdx, out, info) } catch (_: Throwable) {}
                    }
                    enc.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        return
                    }
                }
                outIdx = enc.dequeueOutputBuffer(info, 0)
            }
        }
    }

    private fun postLevels(buf: ByteArray, n: Int) {
        val s = levelSink ?: return
        val now = SystemClock.elapsedRealtime()
        if (now - lastLevelPostMs < 16) return
        lastLevelPostMs = now
        var peakAbs = 0
        var sumSq = 0.0
        var count = 0
        val bb = ByteBuffer.wrap(buf, 0, n).order(ByteOrder.LITTLE_ENDIAN)
        while (bb.remaining() >= 2) {
            val sample = bb.short.toInt()
            val a = if (sample < 0) -sample else sample
            if (a > peakAbs) peakAbs = a
            sumSq += sample.toDouble() * sample.toDouble()
            count++
        }
        if (count == 0) return
        val peak = peakAbs.coerceAtLeast(1) / 32768.0
        val rms = sqrt(sumSq / count) / 32768.0
        val peakDb = max(-80.0, 20.0 * log10(peak))
        val rmsDb = max(-80.0, 20.0 * log10(rms.coerceAtLeast(1.0 / 32768.0)))
        try {
            s.success(mapOf("peakDb" to peakDb, "rmsDb" to rmsDb, "ts" to now))
        } catch (_: Throwable) {}
    }
}
