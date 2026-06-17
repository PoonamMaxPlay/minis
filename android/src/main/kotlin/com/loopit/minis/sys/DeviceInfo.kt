package com.loopit.minis.sys

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaCodecList
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class DeviceInfo(private val appContext: Context, messenger: BinaryMessenger) {
  private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
  private val thermalChannel = EventChannel(messenger, THERMAL_CHANNEL)
  private var thermalSink: EventChannel.EventSink? = null
  private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null

  init {
    methodChannel.setMethodCallHandler { call, result ->
      try {
        when (call.method) {
          "info" -> result.success(buildInfo())
          "thermal" -> result.success(mapOf("state" to thermalState()))
          "battery" -> result.success(buildBattery())
          else -> result.notImplemented()
        }
      } catch (t: Throwable) {
        result.error("device_error", t.message, null)
      }
    }
    thermalChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        thermalSink = events
        if (Build.VERSION.SDK_INT >= 29) {
          val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
          val l = PowerManager.OnThermalStatusChangedListener { _ ->
            thermalSink?.success(mapOf("state" to thermalState()))
          }
          thermalListener = l
          pm.addThermalStatusListener(l)
        }
      }
      override fun onCancel(arguments: Any?) {
        if (Build.VERSION.SDK_INT >= 29 && thermalListener != null) {
          val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
          pm.removeThermalStatusListener(thermalListener!!)
          thermalListener = null
        }
        thermalSink = null
      }
    })
  }

  fun dispose() {
    methodChannel.setMethodCallHandler(null)
    thermalChannel.setStreamHandler(null)
  }

  private fun buildInfo(): Map<String, Any?> {
    val am = appContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
    val codecs = try {
      MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.map { it.name }
    } catch (_: Throwable) { emptyList<String>() }
    val hdr = try {
      MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { info ->
        info.supportedTypes.any { it.contains("video/", true) } &&
          info.name.contains("hevc", true) || info.name.contains("av1", true)
      }
    } catch (_: Throwable) { false }
    return mapOf(
      "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
      "os" to "android",
      "osVersion" to Build.VERSION.RELEASE,
      "sdkInt" to Build.VERSION.SDK_INT,
      "ramMb" to (mem.totalMem / (1024 * 1024)),
      "gpu" to (Build.HARDWARE ?: ""),
      "codecs" to codecs,
      "hdrCapabilities" to mapOf("hevc10" to hdr)
    )
  }

  private fun thermalState(): String {
    if (Build.VERSION.SDK_INT < 29) return "nominal"
    val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
    return when (pm.currentThermalStatus) {
      PowerManager.THERMAL_STATUS_NONE -> "nominal"
      PowerManager.THERMAL_STATUS_LIGHT -> "light"
      PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
      PowerManager.THERMAL_STATUS_SEVERE -> "severe"
      PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
      PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
      PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
      else -> "nominal"
    }
  }

  private fun buildBattery(): Map<String, Any?> {
    val intent: Intent? = appContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
    val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
    val percent = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
    val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
    val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
    return mapOf("percent" to percent, "charging" to charging)
  }

  companion object {
    const val METHOD_CHANNEL = "loopit/minis/device"
    const val THERMAL_CHANNEL = "loopit/minis/device/thermal"
  }
}
