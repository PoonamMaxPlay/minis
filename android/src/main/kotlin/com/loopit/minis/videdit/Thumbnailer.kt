package com.loopit.minis.videdit

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/**
 * Thumbnail generator. The fast path uses [MediaMetadataRetriever] which
 * delegates to platform HW decoders (MediaCodec → SurfaceTexture) on
 * Android 9+. For codecs that the platform can't HW-decode we fall back to
 * the C-side FFmpeg `ff_thumbstrip_run` path.
 *
 * Output is filesystem-cached so repeated scrub strips reuse the JPEGs.
 */
object Thumbnailer {

  fun strip(path: String, count: Int, w: Int, h: Int, cacheRoot: File): List<ByteArray> {
    if (count <= 0) return emptyList()
    val n = count.coerceAtLeast(1)
    val key = cacheKey(path, n, w, h)
    val dir = File(cacheRoot, key).apply { mkdirs() }

    val mmr = MediaMetadataRetriever().apply { setDataSource(path) }
    val durationMs = mmr
        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
        ?.toLongOrNull() ?: 0L
    val list = ArrayList<ByteArray>(n)
    try {
      for (i in 0 until n) {
        val cacheFile = File(dir, "t_$i.jpg")
        if (cacheFile.exists() && cacheFile.length() > 0) {
          list.add(cacheFile.readBytes())
          continue
        }
        val atMs = if (durationMs > 0) (durationMs.toDouble() * i / n).toLong() else 0L
        val bytes = grabAt(mmr, atMs, w, h) ?: continue
        cacheFile.writeBytes(bytes)
        list.add(bytes)
      }
    } finally {
      runCatching { mmr.release() }
    }
    return list
  }

  fun single(context: Context, path: String, atMs: Long, w: Int, h: Int): ByteArray? {
    val mmr = MediaMetadataRetriever().apply { setDataSource(path) }
    try {
      return grabAt(mmr, atMs, w, h)
    } finally {
      runCatching { mmr.release() }
    }
  }

  private fun grabAt(mmr: MediaMetadataRetriever, atMs: Long, w: Int, h: Int): ByteArray? {
    val bmp: Bitmap? = if (android.os.Build.VERSION.SDK_INT >= 27) {
      mmr.getScaledFrameAtTime(atMs * 1000L,
          MediaMetadataRetriever.OPTION_CLOSEST_SYNC, w, h)
    } else {
      mmr.getFrameAtTime(atMs * 1000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        ?.let { Bitmap.createScaledBitmap(it, w, h, true) }
    }
    if (bmp == null) return null
    return ByteArrayOutputStream(64 * 1024).use {
      bmp.compress(Bitmap.CompressFormat.JPEG, 80, it)
      bmp.recycle()
      it.toByteArray()
    }
  }

  private fun cacheKey(path: String, n: Int, w: Int, h: Int): String {
    val f = File(path)
    val seed = "${f.absolutePath}|${f.lastModified()}|$n|${w}x$h"
    val md = MessageDigest.getInstance("SHA-1")
    val digest = md.digest(seed.toByteArray())
    return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
  }
}
