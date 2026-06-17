package com.loopit.minis.audio

import android.os.Build

/**
 * JNI wrapper for low-latency AAudio capture (API 26+). Falls back to
 * unavailable on older devices; integrators should use `WavRecorder` instead.
 */
class AaudioCapture {

    @Volatile private var handle: Long = 0L
    @Volatile private var callback: ((FloatArray) -> Unit)? = null

    fun isAvailable(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nativeLoaded

    fun start(sampleRate: Int, channels: Int, callback: (FloatArray) -> Unit): Boolean {
        if (!isAvailable()) return false
        stop()
        this.callback = callback
        val h = nativeStart(sampleRate, channels, this)
        if (h == 0L) {
            this.callback = null
            return false
        }
        handle = h
        return true
    }

    fun stop() {
        val h = handle
        handle = 0L
        if (h != 0L) {
            try { nativeStop(h) } catch (_: Throwable) {}
        }
        callback = null
    }

    /** Called from C++ data callback on the AAudio capture thread. */
    @Suppress("unused")
    private fun onSamples(samples: FloatArray) {
        try { callback?.invoke(samples) } catch (_: Throwable) {}
    }

    private external fun nativeStart(sampleRate: Int, channels: Int, sink: AaudioCapture): Long
    private external fun nativeStop(handle: Long)

    companion object {
        @Volatile private var nativeLoaded: Boolean = false

        init {
            nativeLoaded = try {
                System.loadLibrary("minis_audio_aaudio")
                true
            } catch (_: Throwable) {
                false
            }
        }
    }
}
