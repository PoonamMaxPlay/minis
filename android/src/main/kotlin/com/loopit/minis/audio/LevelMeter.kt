package com.loopit.minis.audio

import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import kotlin.math.log10
import kotlin.math.max

/**
 * Polls a [MediaRecorder] for max amplitude at ~60 Hz and emits {peakDb, rmsDb,
 * ts} payloads to the audio levels EventChannel. RMS is approximated from peak
 * via a fixed -6 dB offset; a real RMS requires the AudioRecord path (D2.x).
 *
 * TODO(improvement4.md D3): replace amplitude poll with AudioRecord PCM tap
 * once D2.x lands the AudioRecord-based capture path.
 */
class LevelMeter {
    private val handler = Handler(Looper.getMainLooper())
    private var recorder: MediaRecorder? = null
    private var sink: EventChannel.EventSink? = null
    private var running = false
    private var lastPostMs: Long = 0

    private val tick = object : Runnable {
        override fun run() {
            val r = recorder ?: return
            val s = sink
            try {
                val amp = r.maxAmplitude.coerceAtLeast(0)
                val now = SystemClock.elapsedRealtime()
                if (s != null && now - lastPostMs >= 16) {
                    val peak = amp.coerceAtLeast(1) / 32768.0
                    val peakDb = max(-80.0, 20.0 * log10(peak))
                    val rmsDb = max(-80.0, peakDb - 6.0)
                    s.success(
                        mapOf(
                            "peakDb" to peakDb,
                            "rmsDb" to rmsDb,
                            "ts" to now,
                        )
                    )
                    lastPostMs = now
                }
            } catch (_: Throwable) {}
            if (running) handler.postDelayed(this, 16L)
        }
    }

    fun attachSink(s: EventChannel.EventSink?) {
        sink = s
    }

    fun start(r: MediaRecorder) {
        recorder = r
        running = true
        lastPostMs = 0
        handler.removeCallbacks(tick)
        handler.post(tick)
    }

    fun stop() {
        running = false
        handler.removeCallbacks(tick)
        recorder = null
    }
}
