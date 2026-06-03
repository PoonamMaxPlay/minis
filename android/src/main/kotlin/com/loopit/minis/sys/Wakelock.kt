package com.loopit.minis.sys

import android.app.Activity
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class Wakelock(messenger: BinaryMessenger) {
  private val channel = MethodChannel(messenger, CHANNEL)
  @Volatile private var activity: Activity? = null

  init {
    channel.setMethodCallHandler { call, result ->
      val a = activity
      when (call.method) {
        "enable" -> {
          if (a == null) { result.error("no_activity", "No activity attached", null); return@setMethodCallHandler }
          a.runOnUiThread {
            a.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            result.success(null)
          }
        }
        "disable" -> {
          if (a == null) { result.success(null); return@setMethodCallHandler }
          a.runOnUiThread {
            a.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            result.success(null)
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  fun setActivity(a: Activity?) { activity = a }
  fun dispose() {
    val a = activity
    if (a != null) a.runOnUiThread { a.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    channel.setMethodCallHandler(null)
  }

  companion object { const val CHANNEL = "loopit/minis/wakelock" }
}
