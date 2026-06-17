package com.loopit.minis.audio

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel

/**
 * Dispatches to MediaRecorder (AAC), WavRecorder (WAV/PCM16), or OpusRecorder
 * (Opus/Ogg on API 29+). MP3 still pending (needs vendored LAME — D2.x).
 */
class Recorder(private val context: Context) {
    private var recorder: MediaRecorder? = null
    private var outputPath: String = ""
    private var startedAt: Long = 0
    private var pausedAt: Long = 0
    private var accumulated: Long = 0
    private val levelMeter = LevelMeter()
    private val wav = WavRecorder()
    private val opus = OpusRecorder()
    private val micRouter = MicRouter(context)
    private val fx = PlatformAudioFx()
    private val lame = LameStub()
    private var pendingInputId: String? = null
    private var pendingDenoise: Boolean = false
    private var pendingMonitor: Boolean = false
    private var activeFormat: String = "aac"

    fun attachLevelSink(sink: EventChannel.EventSink?) {
        levelMeter.attachSink(sink)
        wav.attachLevelSink(sink)
        opus.attachLevelSink(sink)
    }

    fun listInputs(): List<Map<String, Any?>> = micRouter.listInputs()

    fun setPreferredInput(id: String): Boolean {
        pendingInputId = id
        return micRouter.setInput(id, recorder)
    }

    fun start(
        path: String,
        format: String,
        sampleRate: Int,
        channels: Int,
        bitRate: Int,
        denoise: Boolean = false,
        monitor: Boolean = false,
    ) {
        pendingDenoise = denoise
        pendingMonitor = monitor
        stopInternal(silent = true)
        outputPath = path
        activeFormat = format
        if (format == "mp3") {
            if (!lame.isAvailable()) {
                throw IllegalStateException(
                    "format=mp3 needs vendored libmp3lame.so — see android/src/main/cpp/audio/lame_README.md"
                )
            }
            // MP3 path: capture via WAV, on stop encode via LAME.
            wav.start(path + ".pcm", sampleRate, channels)
            return
        }
        if (format == "wav") {
            wav.start(path, sampleRate, channels)
            fx.attach(audioSessionIdFor(wav), denoise, monitor, agc = monitor)
            return
        }
        if (format == "opus") {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                throw IllegalStateException("format=opus requires API 29+ (improvement4.md D2.x)")
            }
            opus.start(path, sampleRate, channels)
            fx.attach(audioSessionIdFor(opus), denoise, monitor, agc = monitor)
            return
        }
        val r = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }
        val source = if (monitor) MediaRecorder.AudioSource.VOICE_COMMUNICATION
                     else MediaRecorder.AudioSource.MIC
        r.setAudioSource(source)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        r.setAudioSamplingRate(sampleRate)
        r.setAudioChannels(channels)
        r.setAudioEncodingBitRate(bitRate)
        r.setOutputFile(path)
        r.prepare()
        pendingInputId?.let { micRouter.setInput(it, r) }
        r.start()
        recorder = r
        startedAt = SystemClock.elapsedRealtime()
        accumulated = 0
        pausedAt = 0
        levelMeter.start(r)
        if (denoise || monitor) {
            try {
                val sid = r.javaClass.getMethod("getAudioSessionId").invoke(r) as? Int ?: 0
                if (sid != 0) fx.attach(sid, denoise, monitor, agc = monitor)
            } catch (_: Throwable) {}
        }
    }

    private fun audioSessionIdFor(@Suppress("UNUSED_PARAMETER") any: Any): Int = 0

    fun pause() {
        if (activeFormat == "wav") {
            wav.pause(); return
        }
        if (activeFormat == "opus") {
            opus.pause(); return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val r = recorder ?: return
        try {
            r.pause()
            pausedAt = SystemClock.elapsedRealtime()
            accumulated += pausedAt - startedAt
        } catch (_: Throwable) {}
    }

    fun resume() {
        if (activeFormat == "wav") {
            wav.resume(); return
        }
        if (activeFormat == "opus") {
            opus.resume(); return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        val r = recorder ?: return
        try {
            r.resume()
            startedAt = SystemClock.elapsedRealtime()
        } catch (_: Throwable) {}
    }

    fun stop(): Map<String, Any> {
        fx.release()
        if (activeFormat == "mp3") {
            val pcmStop = wav.stop()
            val pcmPath = pcmStop["path"] as String
            val dec = PcmDecoder.decode(pcmPath)
            val ok = lame.encode(dec.samples, dec.sampleRate, dec.channels, outputPath)
            if (!ok) {
                return mapOf("path" to "", "durationMs" to 0,
                    "error" to "lame encode failed (drop libmp3lame.so under jniLibs)")
            }
            java.io.File(pcmPath).delete()
            return mapOf("path" to outputPath, "durationMs" to (pcmStop["durationMs"] ?: 0))
        }
        if (activeFormat == "wav") return wav.stop()
        if (activeFormat == "opus") return opus.stop()
        val r = recorder ?: return mapOf("path" to outputPath, "durationMs" to 0)
        val now = SystemClock.elapsedRealtime()
        val dur = (accumulated + (now - startedAt)).coerceAtLeast(0)
        levelMeter.stop()
        try {
            r.stop()
        } catch (_: Throwable) {}
        try {
            r.release()
        } catch (_: Throwable) {}
        recorder = null
        return mapOf("path" to outputPath, "durationMs" to dur.toInt())
    }

    fun dispose() {
        stopInternal(silent = true)
        wav.dispose()
        opus.dispose()
        fx.release()
        levelMeter.stop()
        levelMeter.attachSink(null)
    }

    private fun stopInternal(silent: Boolean) {
        if (activeFormat == "wav" && wav.isActive()) {
            wav.stop()
            return
        }
        if (activeFormat == "opus" && opus.isActive()) {
            opus.stop()
            return
        }
        val r = recorder ?: return
        levelMeter.stop()
        try { r.stop() } catch (_: Throwable) { if (!silent) throw RuntimeException("recorder stop failed") }
        try { r.release() } catch (_: Throwable) {}
        recorder = null
    }
}
