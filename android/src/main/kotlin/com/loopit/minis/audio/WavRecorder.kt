package com.loopit.minis.audio

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * 16-bit PCM WAV recorder backed by `AudioRecord`. Writes a 44-byte RIFF
 * header on start, appends PCM frames on a daemon thread, fixes up the data
 * and RIFF size fields on stop. Pumps `{peakDb, rmsDb, ts}` at ~60 Hz from
 * the captured PCM (true RMS, unlike the MediaRecorder path).
 */
class WavRecorder {
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var raf: RandomAccessFile? = null
    private var path: String = ""
    private var sampleRate: Int = 44100
    private var channels: Int = 1
    @Volatile private var paused: Boolean = false
    @Volatile private var stopRequested: Boolean = false
    private var startedAt: Long = 0
    private var accumulated: Long = 0
    private var bytesWritten: Long = 0
    private var levelMeter: LevelMeter? = null
    private var levelSink: EventChannel.EventSink? = null
    private var lastLevelPostMs: Long = 0

    fun attachLevelSink(s: EventChannel.EventSink?) {
        levelSink = s
    }

    fun start(path: String, sampleRate: Int, channels: Int) {
        stopSilently()
        this.path = path
        this.sampleRate = sampleRate
        this.channels = channels.coerceIn(1, 2)
        val channelCfg = if (this.channels == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelCfg, encoding)
        if (minBuf <= 0) throw IllegalStateException("AudioRecord.getMinBufferSize=$minBuf")
        val bufSize = max(minBuf, sampleRate * this.channels * 2 / 10) // ~100 ms
        @SuppressWarnings("MissingPermission")
        val ar = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            channelCfg,
            encoding,
            bufSize,
        )
        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            ar.release()
            throw IllegalStateException("AudioRecord init failed")
        }
        File(path).parentFile?.mkdirs()
        val file = RandomAccessFile(path, "rw")
        file.setLength(0)
        writeWavHeader(file, sampleRate, this.channels, dataLen = 0)
        raf = file
        bytesWritten = 0
        paused = false
        stopRequested = false
        startedAt = SystemClock.elapsedRealtime()
        accumulated = 0
        record = ar
        ar.startRecording()
        thread = Thread({ pump(ar, bufSize) }, "minis-wav-rec").apply {
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
        try { thread?.join(500) } catch (_: Throwable) {}
        thread = null
        val ar = record
        record = null
        try { ar?.stop() } catch (_: Throwable) {}
        try { ar?.release() } catch (_: Throwable) {}
        val now = SystemClock.elapsedRealtime()
        val dur = (accumulated + if (paused) 0L else (now - startedAt)).coerceAtLeast(0)
        try {
            raf?.let { fixUpHeader(it, bytesWritten) }
        } finally {
            try { raf?.close() } catch (_: Throwable) {}
            raf = null
        }
        return mapOf("path" to path, "durationMs" to dur.toInt())
    }

    fun dispose() {
        stopSilently()
        levelSink = null
    }

    fun isActive(): Boolean = record != null

    private fun stopSilently() {
        if (record == null) return
        stopRequested = true
        try { thread?.join(200) } catch (_: Throwable) {}
        thread = null
        try { record?.stop() } catch (_: Throwable) {}
        try { record?.release() } catch (_: Throwable) {}
        record = null
        try { raf?.close() } catch (_: Throwable) {}
        raf = null
    }

    private fun pump(ar: AudioRecord, bufSize: Int) {
        val buf = ByteArray(bufSize)
        while (!stopRequested) {
            if (paused) {
                try { Thread.sleep(10) } catch (_: InterruptedException) {}
                continue
            }
            val n = try { ar.read(buf, 0, buf.size) } catch (_: Throwable) { -1 }
            if (n <= 0) continue
            try {
                raf?.write(buf, 0, n)
                bytesWritten += n
            } catch (_: Throwable) {
                break
            }
            postLevels(buf, n)
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

    private fun writeWavHeader(file: RandomAccessFile, sr: Int, ch: Int, dataLen: Int) {
        val byteRate = sr * ch * 16 / 8
        val blockAlign = ch * 16 / 8
        val riffSize = 36 + dataLen
        val hdr = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        hdr.put("RIFF".toByteArray(Charsets.US_ASCII))
        hdr.putInt(riffSize)
        hdr.put("WAVE".toByteArray(Charsets.US_ASCII))
        hdr.put("fmt ".toByteArray(Charsets.US_ASCII))
        hdr.putInt(16)
        hdr.putShort(1) // PCM
        hdr.putShort(ch.toShort())
        hdr.putInt(sr)
        hdr.putInt(byteRate)
        hdr.putShort(blockAlign.toShort())
        hdr.putShort(16)
        hdr.put("data".toByteArray(Charsets.US_ASCII))
        hdr.putInt(dataLen)
        file.write(hdr.array())
    }

    private fun fixUpHeader(file: RandomAccessFile, dataLen: Long) {
        val riffSize = (36 + dataLen).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        val dataSize = dataLen.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        file.seek(4)
        file.write(intLe(riffSize))
        file.seek(40)
        file.write(intLe(dataSize))
    }

    private fun intLe(v: Int): ByteArray = byteArrayOf(
        (v and 0xFF).toByte(),
        ((v ushr 8) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(),
        ((v ushr 24) and 0xFF).toByte(),
    )
}
