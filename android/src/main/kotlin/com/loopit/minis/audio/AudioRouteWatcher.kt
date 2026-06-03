package com.loopit.minis.audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Posts route-change + becoming-noisy events to the audio state EventChannel.
 * Survives BT A2DP↔HFP↔built-in flips during recording — the AudioRecord /
 * MediaRecorder stream is kept open; the kernel handles the splice.
 */
class AudioRouteWatcher(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val audioManager: AudioManager =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            post(
                mapOf(
                    "type" to "routeChange",
                    "reason" to "becomingNoisy",
                )
            )
        }
    }
    private var noisyRegistered = false

    private val deviceCallback: AudioDeviceCallback? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) {
                    post(
                        mapOf(
                            "type" to "routeChange",
                            "reason" to "deviceAdded",
                            "devices" to (added?.map(::describe) ?: emptyList<String>()),
                        )
                    )
                }

                override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) {
                    post(
                        mapOf(
                            "type" to "routeChange",
                            "reason" to "deviceRemoved",
                            "devices" to (removed?.map(::describe) ?: emptyList<String>()),
                        )
                    )
                }
            }
        } else null

    fun attachSink(s: EventChannel.EventSink?) {
        sink = s
    }

    fun start() {
        if (!noisyRegistered) {
            context.registerReceiver(
                noisyReceiver,
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            )
            noisyRegistered = true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && deviceCallback != null) {
            audioManager.registerAudioDeviceCallback(deviceCallback, handler)
        }
    }

    fun stop() {
        if (noisyRegistered) {
            try { context.unregisterReceiver(noisyReceiver) } catch (_: Throwable) {}
            noisyRegistered = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && deviceCallback != null) {
            try { audioManager.unregisterAudioDeviceCallback(deviceCallback) } catch (_: Throwable) {}
        }
    }

    private fun post(payload: Map<String, Any?>) {
        val s = sink ?: return
        handler.post {
            try { s.success(payload) } catch (_: Throwable) {}
        }
    }

    private fun describe(d: AudioDeviceInfo): Map<String, Any?> = mapOf(
        "id" to d.id,
        "type" to d.type,
        "productName" to (d.productName?.toString() ?: ""),
        "isSource" to d.isSource,
        "isSink" to d.isSink,
    )
}
