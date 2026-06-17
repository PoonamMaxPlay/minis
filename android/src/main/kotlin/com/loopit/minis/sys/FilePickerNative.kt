package com.loopit.minis.sys

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class FilePickerNative(private val appContext: Context) {

  fun pickFile(
    args: Map<*, *>,
    result: MethodChannel.Result,
    launch: (Intent, (Int, Intent?) -> Unit) -> Unit
  ) {
    val multi = (args["multi"] as? Boolean) ?: false
    val mimeTypes = (args["mimeTypes"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
    val extensions = (args["extensions"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      if (mimeTypes.size == 1) type = mimeTypes[0]
      else if (mimeTypes.size > 1) {
        type = "*/*"
        putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
      } else {
        type = "*/*"
      }
      if (multi) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    launch(intent) { rc, data ->
      if (rc != Activity.RESULT_OK || data == null) {
        result.success(mapOf("items" to emptyList<Any>())); return@launch
      }
      val items = mutableListOf<Map<String, Any?>>()
      val clip = data.clipData
      if (clip != null) {
        for (i in 0 until clip.itemCount) {
          val u = clip.getItemAt(i).uri ?: continue
          materialize(u, extensions)?.let { items.add(it) }
        }
      } else {
        data.data?.let { u -> materialize(u, extensions)?.let { items.add(it) } }
      }
      result.success(mapOf("items" to items))
    }
  }

  private fun materialize(uri: Uri, allowedExts: List<String>): Map<String, Any?>? {
    val cr = appContext.contentResolver
    val mime = cr.getType(uri) ?: "application/octet-stream"
    val name = queryName(uri) ?: "file_${UUID.randomUUID()}"
    val ext = name.substringAfterLast('.', "").lowercase()
    if (allowedExts.isNotEmpty() && ext !in allowedExts.map { it.lowercase().trimStart('.') }) return null
    val safeName = "${UUID.randomUUID()}_${name.takeLast(120)}"
    val out = File(appContext.cacheDir, safeName)
    var size = 0L
    cr.openInputStream(uri).use { input ->
      if (input == null) return null
      out.outputStream().use { o -> size = input.copyTo(o) }
    }
    return mapOf(
      "path" to out.absolutePath,
      "mime" to mime,
      "size" to size,
      "name" to name
    )
  }

  private fun queryName(uri: Uri): String? {
    appContext.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
      val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
      if (c.moveToFirst() && idx >= 0) return c.getString(idx)
    }
    return uri.lastPathSegment
  }
}
