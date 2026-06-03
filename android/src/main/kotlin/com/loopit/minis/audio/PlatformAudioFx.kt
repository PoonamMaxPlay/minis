package com.loopit.minis.audio

import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor

/**
 * Wraps Android built-in AEC / noise suppression / AGC tied to an
 * `AudioRecord`'s session id. Each effect is best-effort: returns false in
 * the result map when unavailable or when enable() failed.
 */
class PlatformAudioFx {

    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var agc: AutomaticGainControl? = null

    fun attach(audioSessionId: Int, denoise: Boolean, echoCancel: Boolean, agc: Boolean): Map<String, Boolean> {
        release()
        val nsOn = if (denoise) tryEnableNs(audioSessionId) else false
        val aecOn = if (echoCancel) tryEnableAec(audioSessionId) else false
        val agcOn = if (agc) tryEnableAgc(audioSessionId) else false
        return mapOf("noise" to nsOn, "echo" to aecOn, "agc" to agcOn)
    }

    fun release() {
        try { aec?.enabled = false } catch (_: Throwable) {}
        try { aec?.release() } catch (_: Throwable) {}
        aec = null
        try { ns?.enabled = false } catch (_: Throwable) {}
        try { ns?.release() } catch (_: Throwable) {}
        ns = null
        try { this.agc?.enabled = false } catch (_: Throwable) {}
        try { this.agc?.release() } catch (_: Throwable) {}
        this.agc = null
    }

    private fun tryEnableNs(sessionId: Int): Boolean {
        if (!NoiseSuppressor.isAvailable()) return false
        return try {
            val n = NoiseSuppressor.create(sessionId) ?: return false
            ns = n
            n.enabled = true
            n.enabled
        } catch (_: Throwable) { false }
    }

    private fun tryEnableAec(sessionId: Int): Boolean {
        if (!AcousticEchoCanceler.isAvailable()) return false
        return try {
            val a = AcousticEchoCanceler.create(sessionId) ?: return false
            aec = a
            a.enabled = true
            a.enabled
        } catch (_: Throwable) { false }
    }

    private fun tryEnableAgc(sessionId: Int): Boolean {
        if (!AutomaticGainControl.isAvailable()) return false
        return try {
            val g = AutomaticGainControl.create(sessionId) ?: return false
            this.agc = g
            g.enabled = true
            g.enabled
        } catch (_: Throwable) { false }
    }
}
