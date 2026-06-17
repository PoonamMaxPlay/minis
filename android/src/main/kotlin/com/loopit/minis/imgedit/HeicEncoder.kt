package com.loopit.minis.imgedit

import android.graphics.Bitmap
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import java.io.File

/**
 * Thin wrapper around `android.media.MediaMuxer` + `HeifWriter` so the
 * export path can request HEIC without depending on extra libs.
 *
 * On pre-P devices this falls back to JPEG (callers re-check `path`
 * extension after write).
 */
object HeicEncoder {
    private const val TAG = "MinisImgEditHeic"

    fun encode(target: File, bitmap: Bitmap, quality: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            Log.w(TAG, "HEIC unsupported on API ${Build.VERSION.SDK_INT}; falling back to JPEG")
            return target.outputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            }
        }
        return try {
            val writerClass = Class.forName("android.media.HeifWriter")
            val builderClass = Class.forName("android.media.HeifWriter\$Builder")
            val builder = builderClass.getConstructor(
                String::class.java, Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType,
            ).newInstance(target.absolutePath, bitmap.width, bitmap.height, /* inputMode */ 2)
            builderClass.getMethod("setQuality", Int::class.javaPrimitiveType)
                .invoke(builder, quality)
            val writer = builderClass.getMethod("build").invoke(builder)
            writerClass.getMethod("start").invoke(writer)
            writerClass.getMethod("addBitmap", Bitmap::class.java).invoke(writer, bitmap)
            writerClass.getMethod("stop", Long::class.javaPrimitiveType)
                .invoke(writer, 5_000L)
            writerClass.getMethod("close").invoke(writer)
            true
        } catch (t: Throwable) {
            Log.w(TAG, "HEIC encode failed (${t.message}); falling back to JPEG")
            target.outputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            }
        }
    }
    @Suppress("unused")
    private val unused: MediaCodecInfo? = null
    @Suppress("unused")
    private val unusedFmt: MediaFormat? = null
}
