package com.loopit.minis.sys

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

class Share(private val appContext: Context, messenger: BinaryMessenger) {
  private val channel = MethodChannel(messenger, CHANNEL)
  @Volatile private var activity: Activity? = null

  init {
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "share" -> {
          val args = call.arguments as? Map<*, *>
          val paths = (args?.get("paths") as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
          val text = args?.get("text") as? String
          val subject = args?.get("subject") as? String
          shareOut(paths, text, subject, result)
        }
        else -> result.notImplemented()
      }
    }
  }

  fun setActivity(a: Activity?) { activity = a }
  fun dispose() { channel.setMethodCallHandler(null) }

  private fun authority() = "${appContext.packageName}.loopit_minis.fileprovider"

  private fun shareOut(paths: List<String>, text: String?, subject: String?, result: MethodChannel.Result) {
    val a = activity ?: return result.error("no_activity", "No activity", null)
    val uris = paths.map { p ->
      val f = File(p)
      try {
        FileProvider.getUriForFile(appContext, authority(), f)
      } catch (_: Throwable) {
        Uri.fromFile(f)
      }
    }
    val intent = if (uris.size == 1) {
      Intent(Intent.ACTION_SEND).apply {
        type = appContext.contentResolver.getType(uris.first()) ?: "*/*"
        putExtra(Intent.EXTRA_STREAM, uris.first())
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      }
    } else if (uris.size > 1) {
      Intent(Intent.ACTION_SEND_MULTIPLE).apply {
        type = "*/*"
        putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      }
    } else {
      Intent(Intent.ACTION_SEND).apply { type = "text/plain" }
    }
    if (!text.isNullOrEmpty()) intent.putExtra(Intent.EXTRA_TEXT, text)
    if (!subject.isNullOrEmpty()) intent.putExtra(Intent.EXTRA_SUBJECT, subject)
    a.startActivity(Intent.createChooser(intent, subject ?: "Share"))
    result.success(null)
  }

  companion object { const val CHANNEL = "loopit/minis/share" }
}
