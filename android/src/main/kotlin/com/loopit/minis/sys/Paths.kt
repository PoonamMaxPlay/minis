package com.loopit.minis.sys

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class Paths(private val appContext: Context, messenger: BinaryMessenger) {
  private val channel = MethodChannel(messenger, CHANNEL)

  init {
    channel.setMethodCallHandler { call, result ->
      try {
        when (call.method) {
          "cacheDir" -> result.success(mapOf("path" to appContext.cacheDir.absolutePath))
          "appSupportDir" -> {
            val dir = File(appContext.filesDir, "support").apply { if (!exists()) mkdirs() }
            result.success(mapOf("path" to dir.absolutePath))
          }
          "documentsDir" -> result.success(mapOf("path" to appContext.filesDir.absolutePath))
          "externalDir" -> {
            val dir = appContext.getExternalFilesDir(null)
            result.success(mapOf("path" to (dir?.absolutePath)))
          }
          "tempFile" -> {
            val ext = call.argument<String>("ext")?.trimStart('.')?.lowercase() ?: "tmp"
            val name = "${UUID.randomUUID()}.$ext"
            val f = File(appContext.cacheDir, name)
            result.success(mapOf("path" to f.absolutePath))
          }
          "join" -> {
            val parts = call.argument<List<String>>("parts") ?: emptyList()
            val joined = parts.fold(File("")) { acc, p ->
              if (acc.path.isEmpty()) File(p) else File(acc, p)
            }.path
            result.success(mapOf("path" to joined))
          }
          "extension" -> {
            val p = call.argument<String>("path") ?: ""
            val idx = p.lastIndexOf('.')
            val sep = maxOf(p.lastIndexOf('/'), p.lastIndexOf('\\'))
            val ext = if (idx > sep && idx >= 0) p.substring(idx) else ""
            result.success(mapOf("ext" to ext))
          }
          "basename" -> {
            val p = call.argument<String>("path") ?: ""
            result.success(mapOf("name" to File(p).name))
          }
          else -> result.notImplemented()
        }
      } catch (t: Throwable) {
        result.error("paths_error", t.message, null)
      }
    }
  }

  fun dispose() { channel.setMethodCallHandler(null) }

  companion object { const val CHANNEL = "loopit/minis/paths" }
}
