package com.loopit.minis.sys

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class Permissions(
  private val appContext: Context,
  messenger: BinaryMessenger
) : PluginRegistry.RequestPermissionsResultListener {

  private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
  private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
  @Volatile private var activity: Activity? = null
  private var eventSink: EventChannel.EventSink? = null

  private val pending = mutableMapOf<Int, PendingRequest>()
  private var nextCode = 9000

  data class PendingRequest(val keys: List<String>, val result: MethodChannel.Result, val multi: Boolean)

  init {
    methodChannel.setMethodCallHandler { call, result ->
      when (call.method) {
        "check" -> {
          val key = call.argument<String>("permission") ?: return@setMethodCallHandler result.error("arg", "permission required", null)
          result.success(mapOf("status" to statusOf(key)))
        }
        "request" -> {
          val key = call.argument<String>("permission") ?: return@setMethodCallHandler result.error("arg", "permission required", null)
          requestPerms(listOf(key), result, multi = false)
        }
        "requestMulti" -> {
          val keys = call.argument<List<String>>("permissions") ?: emptyList()
          requestPerms(keys, result, multi = true)
        }
        "openSettings" -> {
          openAppSettings()
          result.success(null)
        }
        else -> result.notImplemented()
      }
    }
    eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { eventSink = events }
      override fun onCancel(arguments: Any?) { eventSink = null }
    })
  }

  fun setActivity(a: Activity?) { activity = a }
  fun dispose() {
    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
  }

  fun notifySettingsReturn() {
    eventSink?.success(mapOf("kind" to "settingsReturned"))
  }

  private fun manifestPermsFor(key: String): List<String> = when (key) {
    "camera" -> listOf(Manifest.permission.CAMERA)
    "microphone" -> listOf(Manifest.permission.RECORD_AUDIO)
    "photos" -> if (Build.VERSION.SDK_INT >= 33)
      listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
    else listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    "photosAdd" -> if (Build.VERSION.SDK_INT >= 29) emptyList()
      else listOf(Manifest.permission.WRITE_EXTERNAL_STORAGE)
    "location" -> listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    "locationAlways" -> if (Build.VERSION.SDK_INT >= 29)
      listOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
    else listOf(Manifest.permission.ACCESS_FINE_LOCATION)
    "notification" -> if (Build.VERSION.SDK_INT >= 33)
      listOf(Manifest.permission.POST_NOTIFICATIONS) else emptyList()
    "storage" -> listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    else -> emptyList()
  }

  private fun statusOf(key: String): String {
    val perms = manifestPermsFor(key)
    if (perms.isEmpty()) return "granted"
    val allGranted = perms.all {
      ContextCompat.checkSelfPermission(appContext, it) == PackageManager.PERMISSION_GRANTED
    }
    if (allGranted) return "granted"
    val a = activity ?: return "denied"
    val permanently = perms.all { !ActivityCompat.shouldShowRequestPermissionRationale(a, it) }
    val anyAsked = perms.any { wasEverAsked(it) }
    return if (permanently && anyAsked) "permDenied" else "denied"
  }

  private fun wasEverAsked(perm: String): Boolean {
    val sp = appContext.getSharedPreferences("loopit_minis_perms", Context.MODE_PRIVATE)
    return sp.getBoolean(perm, false)
  }
  private fun markAsked(perms: Array<out String>) {
    val sp = appContext.getSharedPreferences("loopit_minis_perms", Context.MODE_PRIVATE).edit()
    perms.forEach { sp.putBoolean(it, true) }
    sp.apply()
  }

  private fun requestPerms(keys: List<String>, result: MethodChannel.Result, multi: Boolean) {
    val a = activity
    if (a == null) {
      if (multi) {
        result.success(mapOf("map" to keys.associateWith { "denied" }))
      } else {
        result.success(mapOf("status" to "denied"))
      }
      return
    }
    val manifestPerms = keys.flatMap { manifestPermsFor(it) }.distinct()
    if (manifestPerms.isEmpty()) {
      if (multi) result.success(mapOf("map" to keys.associateWith { statusOf(it) }))
      else result.success(mapOf("status" to statusOf(keys.first())))
      return
    }
    val code = nextCode++
    pending[code] = PendingRequest(keys, result, multi)
    markAsked(manifestPerms.toTypedArray())
    ActivityCompat.requestPermissions(a, manifestPerms.toTypedArray(), code)
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray
  ): Boolean {
    val req = pending.remove(requestCode) ?: return false
    val statuses = req.keys.associateWith { statusOf(it) }
    if (req.multi) {
      req.result.success(mapOf("map" to statuses))
    } else {
      req.result.success(mapOf("status" to (statuses[req.keys.first()] ?: "denied")))
    }
    return true
  }

  private fun openAppSettings() {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
      data = Uri.fromParts("package", appContext.packageName, null)
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    appContext.startActivity(intent)
  }

  companion object {
    const val METHOD_CHANNEL = "loopit/minis/permissions"
    const val EVENT_CHANNEL = "loopit/minis/permissions/events"
  }
}
