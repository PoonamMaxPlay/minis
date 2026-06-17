package com.loopit.minis.camera

import android.os.Handler
import android.os.HandlerThread
import java.util.concurrent.atomic.AtomicLong

/**
 * Watchdog: emits [onTimeout] when no frame arrives within [thresholdMs].
 * Call [tick] from the image-analysis / preview callback.
 */
class FrameWatchdog(private val thresholdMs: Long = 250) {
    fun interface Listener { fun onTimeout(noFrameMs: Long) }

    private val thread = HandlerThread("MinisFrameWatchdog").apply { start() }
    private val handler = Handler(thread.looper)
    private val last = AtomicLong(System.currentTimeMillis())
    private var listener: Listener? = null
    private var running = false

    fun setListener(l: Listener?) { listener = l }

    fun tick() { last.set(System.currentTimeMillis()) }

    fun start() {
        if (running) return
        running = true
        last.set(System.currentTimeMillis())
        handler.postDelayed(loop, thresholdMs)
    }

    fun stop() {
        running = false
        handler.removeCallbacksAndMessages(null)
    }

    fun release() {
        stop()
        thread.quitSafely()
    }

    private val loop = object : Runnable {
        override fun run() {
            if (!running) return
            val gap = System.currentTimeMillis() - last.get()
            if (gap > thresholdMs) listener?.onTimeout(gap)
            handler.postDelayed(this, thresholdMs)
        }
    }
}
