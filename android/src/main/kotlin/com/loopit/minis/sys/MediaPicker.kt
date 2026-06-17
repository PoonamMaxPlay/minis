package com.loopit.minis.sys

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.UUID

class MediaPicker(
  private val appContext: Context,
  messenger: BinaryMessenger,
  private val filePicker: FilePickerNative
) : PluginRegistry.ActivityResultListener {

  private val channel = MethodChannel(messenger, CHANNEL)
  @Volatile private var activity: Activity? = null
  private val pending = mutableMapOf<Int, (Int, Intent?) -> Unit>()
  private var nextCode = 7000

  init {
    channel.setMethodCallHandler { call, result ->
      val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
      when (call.method) {
        "pickImage" -> pickImage(args, result)
        "pickVideo" -> pickVideo(args, result)
        "pickMedia" -> pickMedia(args, result)
        "pickFile" -> filePicker.pickFile(args, result, ::launchForResult)
        "saveToGallery" -> saveToGallery(args, result)
        "share" -> result.notImplemented()
        else -> result.notImplemented()
      }
    }
  }

  fun setActivity(a: Activity?) { activity = a }
  fun dispose() { channel.setMethodCallHandler(null) }

  fun launchForResult(intent: Intent, cb: (Int, Intent?) -> Unit) {
    val a = activity ?: return cb(Activity.RESULT_CANCELED, null)
    val code = nextCode++
    pending[code] = cb
    a.startActivityForResult(intent, code)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    val cb = pending.remove(requestCode) ?: return false
    cb(resultCode, data)
    return true
  }

  private fun pickImage(args: Map<*, *>, result: MethodChannel.Result) {
    val source = args["source"] as? String ?: "gallery"
    if (source == "camera") {
      val out = File(appContext.cacheDir, "img_${UUID.randomUUID()}.jpg")
      val authority = "${appContext.packageName}.loopit_minis.fileprovider"
      val uri = try {
        androidx.core.content.FileProvider.getUriForFile(appContext, authority, out)
      } catch (_: Throwable) { Uri.fromFile(out) }
      val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
        putExtra(MediaStore.EXTRA_OUTPUT, uri)
        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
      }
      launchForResult(intent) { rc, _ ->
        if (rc == Activity.RESULT_OK && out.exists()) {
          result.success(describe(out, "image/jpeg"))
        } else {
          result.success(null)
        }
      }
    } else {
      val intent = pickIntent(arrayOf("image/*"), multi = false)
      launchForResult(intent) { rc, data ->
        if (rc == Activity.RESULT_OK && data != null) {
          val uri = data.data
          if (uri == null) result.success(null) else result.success(copyToCache(uri))
        } else result.success(null)
      }
    }
  }

  private fun pickVideo(args: Map<*, *>, result: MethodChannel.Result) {
    val source = args["source"] as? String ?: "gallery"
    if (source == "camera") {
      val intent = Intent(MediaStore.ACTION_VIDEO_CAPTURE)
      val maxMs = (args["maxDurationMs"] as? Number)?.toLong()
      if (maxMs != null) intent.putExtra(MediaStore.EXTRA_DURATION_LIMIT, (maxMs / 1000).toInt())
      launchForResult(intent) { rc, data ->
        if (rc == Activity.RESULT_OK && data?.data != null) result.success(copyToCache(data.data!!))
        else result.success(null)
      }
    } else {
      val intent = pickIntent(arrayOf("video/*"), multi = false)
      launchForResult(intent) { rc, data ->
        if (rc == Activity.RESULT_OK && data?.data != null) result.success(copyToCache(data.data!!))
        else result.success(null)
      }
    }
  }

  private fun pickMedia(args: Map<*, *>, result: MethodChannel.Result) {
    val multi = (args["multi"] as? Boolean) ?: false
    val types = (args["types"] as? List<*>)?.mapNotNull { it as? String } ?: listOf("image", "video")
    val mimes = types.map { if (it == "image") "image/*" else if (it == "video") "video/*" else it }.toTypedArray()
    val intent = pickIntent(mimes, multi)
    launchForResult(intent) { rc, data ->
      if (rc != Activity.RESULT_OK || data == null) { result.success(mapOf("items" to emptyList<Any>())); return@launchForResult }
      val items = mutableListOf<Map<String, Any?>>()
      val clip = data.clipData
      if (clip != null) {
        for (i in 0 until clip.itemCount) {
          val u = clip.getItemAt(i).uri ?: continue
          items.add(copyToCache(u) ?: continue)
        }
      } else {
        val u = data.data
        if (u != null) copyToCache(u)?.let { items.add(it) }
      }
      result.success(mapOf("items" to items))
    }
  }

  private fun saveToGallery(args: Map<*, *>, result: MethodChannel.Result) {
    val path = args["path"] as? String ?: return result.error("arg", "path required", null)
    val album = args["album"] as? String
    val src = File(path)
    if (!src.exists()) return result.error("missing", "file does not exist", null)
    val ext = src.extension.lowercase()
    val isVideo = ext in setOf("mp4", "mov", "m4v", "webm", "3gp", "mkv")
    val mime = when {
      isVideo -> "video/${if (ext == "mov") "quicktime" else ext}"
      ext == "png" -> "image/png"
      ext == "webp" -> "image/webp"
      else -> "image/jpeg"
    }
    val collection = if (Build.VERSION.SDK_INT >= 29) {
      if (isVideo) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
      else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    } else {
      if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    }
    val rel = if (Build.VERSION.SDK_INT >= 29) {
      val base = if (isVideo) android.os.Environment.DIRECTORY_MOVIES else android.os.Environment.DIRECTORY_PICTURES
      if (album.isNullOrEmpty()) base else "$base/$album"
    } else null
    val values = ContentValues().apply {
      put(MediaStore.MediaColumns.DISPLAY_NAME, src.name)
      put(MediaStore.MediaColumns.MIME_TYPE, mime)
      if (Build.VERSION.SDK_INT >= 29 && rel != null) put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
    }
    val uri = appContext.contentResolver.insert(collection, values) ?: return result.error("save_fail", "insert failed", null)
    try {
      appContext.contentResolver.openOutputStream(uri).use { out ->
        if (out == null) throw IllegalStateException("no output stream")
        src.inputStream().use { it.copyTo(out) }
      }
      result.success(mapOf("uri" to uri.toString()))
    } catch (t: Throwable) {
      appContext.contentResolver.delete(uri, null, null)
      result.error("save_fail", t.message, null)
    }
  }

  private fun pickIntent(mimes: Array<String>, multi: Boolean): Intent {
    val intent = if (Build.VERSION.SDK_INT >= 33) {
      Intent(MediaStore.ACTION_PICK_IMAGES).apply {
        if (mimes.size == 1) type = mimes[0]
        if (multi) putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 50)
      }
    } else {
      Intent(Intent.ACTION_GET_CONTENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = if (mimes.size == 1) mimes[0] else "*/*"
        if (mimes.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, mimes)
        if (multi) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
      }
    }
    return intent
  }

  fun copyToCache(uri: Uri): Map<String, Any?>? {
    val mime = appContext.contentResolver.getType(uri) ?: "application/octet-stream"
    val extGuess = when {
      mime.startsWith("image/") -> mime.removePrefix("image/")
      mime.startsWith("video/") -> mime.removePrefix("video/")
      else -> "bin"
    }.let { if (it == "jpeg") "jpg" else it }
    val out = File(appContext.cacheDir, "pick_${UUID.randomUUID()}.$extGuess")
    var size = 0L
    appContext.contentResolver.openInputStream(uri).use { input ->
      if (input == null) return null
      out.outputStream().use { output -> size = input.copyTo(output) }
    }
    return describe(out, mime, size)
  }

  private fun describe(file: File, mime: String, sizeOverride: Long? = null): Map<String, Any?> {
    val size = sizeOverride ?: file.length()
    var w = 0; var h = 0; var dur = 0L
    if (mime.startsWith("video/")) {
      try {
        val mmr = android.media.MediaMetadataRetriever()
        mmr.setDataSource(file.absolutePath)
        w = mmr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        h = mmr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        dur = mmr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        mmr.release()
      } catch (_: Throwable) {}
    } else if (mime.startsWith("image/")) {
      try {
        val opts = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeFile(file.absolutePath, opts)
        w = opts.outWidth; h = opts.outHeight
      } catch (_: Throwable) {}
    }
    return mapOf(
      "path" to file.absolutePath,
      "mime" to mime,
      "size" to size,
      "w" to w,
      "h" to h,
      "durationMs" to dur
    )
  }

  companion object { const val CHANNEL = "loopit/minis/picker" }
}
