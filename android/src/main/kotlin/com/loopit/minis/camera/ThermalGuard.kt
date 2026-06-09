package com.loopit.minis.camera

import android.content.Context
import android.os.Build
import android.os.PowerManager
import androidx.annotation.RequiresApi

/**
 * Subscribes to [PowerManager.OnThermalStatusChangedListener]; signals when fps/bitrate
 * should be downgraded.
 */
class ThermalGuard(context: Context) {
    fun interface Listener { fun onLevel(level: Int) }

    private val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
    private var listeners = mutableListOf<Listener>()

    private val osListener = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        PowerManager.OnThermalStatusChangedListener { status ->
            synchronized(listeners) { listeners.toList() }.forEach { it.onLevel(status) }
        }
    } else null

    @Volatile private var attached = false

    fun addListener(l: Listener) { synchronized(listeners) { listeners.add(l) } }

    @RequiresApi(Build.VERSION_CODES.Q)
    fun attach() {
        val l = osListener ?: return
        if (attached) return
        runCatching { pm?.addThermalStatusListener(l) }.onSuccess { attached = true }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    fun detach() {
        val l = osListener ?: return
        // PowerManager.removeThermalStatusListener throws
        // IllegalArgumentException when the listener was never registered.
        // CameraXEngine.release() calls detach() unconditionally during the
        // first dispose (before any successful attach), so guard the unregister
        // with both the attached flag and a try/catch.
        if (!attached) return
        runCatching { pm?.removeThermalStatusListener(l) }
        attached = false
    }
}
