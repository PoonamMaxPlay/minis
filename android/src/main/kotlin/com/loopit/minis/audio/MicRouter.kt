package com.loopit.minis.audio

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Build

/**
 * Lists input devices and applies a preferred routing on the active recorder.
 * Routing applies to `MediaRecorder` from API 28+ (setPreferredDevice). Below
 * that, [setInput] is a no-op — Android picks the device automatically.
 */
class MicRouter(context: Context) {
    private val audioManager: AudioManager =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    fun listInputs(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
        return devices.map { d ->
            mapOf(
                "id" to d.id.toString(),
                "label" to (d.productName?.toString() ?: kindName(d.type)),
                "kind" to kindName(d.type),
            )
        }
    }

    fun setInput(id: String, recorder: MediaRecorder?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val device = findDevice(id) ?: return false
        val r = recorder ?: return true
        return r.setPreferredDevice(device)
    }

    fun findDevice(id: String): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        val target = id.toIntOrNull() ?: return null
        return audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { it.id == target }
    }

    private fun kindName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtin"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetoothSco"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetoothA2dp"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wiredHeadset"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usbHeadset"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usbDevice"
        AudioDeviceInfo.TYPE_TELEPHONY -> "telephony"
        AudioDeviceInfo.TYPE_DOCK -> "dock"
        AudioDeviceInfo.TYPE_FM_TUNER -> "fmTuner"
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "lineAnalog"
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> "lineDigital"
        AudioDeviceInfo.TYPE_AUX_LINE -> "auxLine"
        else -> "unknown"
    }
}
