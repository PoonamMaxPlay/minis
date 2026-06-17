package com.loopit.minis.imgedit

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileOutputStream

/**
 * Bitmap → JPEG/PNG/HEIC/WebP encode. HEIC uses `HeifWriter` on API 28+.
 *
 * When the native GL pipeline has produced an output FBO via
 * [ImageEditNative.readPixels], the encoded bytes come from there.
 * If the renderer is not yet producing pixels (skeleton phase), the
 * source image is re-encoded so the round-trip stays unbroken — host
 * flows that depend on a written file still get one.
 */
object Exporter {
    private const val TAG = "MinisImgEditExport"

    fun write(
        viewId: Int,
        sourcePath: String?,
        layers: LayerStack,
        format: String,
        quality: Int,
        maxDim: Int?,
        path: String,
    ): Map<String, Any?> {
        val target = File(path).also { it.parentFile?.mkdirs() }
        var bitmap = ImageEditNative.readPixels(viewId)
        if (bitmap == null) {
            bitmap = decodeSource(sourcePath, maxDim)
        }
        if (bitmap == null) {
            return mapOf("path" to "", "w" to 0, "h" to 0, "size" to 0)
        }
        if (maxDim != null) {
            bitmap = downscale(bitmap, maxDim)
        }
        return try {
            FileOutputStream(target).use { out ->
                when (format) {
                    "png" -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                    "webp" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        bitmap.compress(Bitmap.CompressFormat.WEBP_LOSSY, quality, out)
                    } else {
                        @Suppress("DEPRECATION")
                        bitmap.compress(Bitmap.CompressFormat.WEBP, quality, out)
                    }
                    "heic" -> HeicEncoder.encode(target, bitmap, quality)
                    else -> bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
                }
            }
            mapOf(
                "path" to target.absolutePath,
                "w" to bitmap.width,
                "h" to bitmap.height,
                "size" to target.length(),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "encode failed: ${t.message}")
            mapOf("path" to "", "w" to 0, "h" to 0, "size" to 0)
        }
    }

    private fun decodeSource(sourcePath: String?, maxDim: Int?): Bitmap? {
        if (sourcePath.isNullOrEmpty()) return null
        val f = File(sourcePath)
        if (!f.exists()) return null
        val opts = BitmapFactory.Options()
        if (maxDim != null) {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(sourcePath, bounds)
            opts.inSampleSize = computeSampleSize(bounds.outWidth, bounds.outHeight, maxDim)
        }
        return BitmapFactory.decodeFile(sourcePath, opts)
    }

    private fun downscale(bitmap: Bitmap, maxDim: Int): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        val longest = maxOf(w, h)
        if (longest <= maxDim) return bitmap
        val scale = maxDim.toDouble() / longest
        val nw = (w * scale).toInt().coerceAtLeast(1)
        val nh = (h * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(bitmap, nw, nh, true)
    }

    private fun computeSampleSize(w: Int, h: Int, maxDim: Int): Int {
        var sample = 1
        var cw = w
        var ch = h
        while (cw / 2 >= maxDim && ch / 2 >= maxDim) {
            cw /= 2
            ch /= 2
            sample *= 2
        }
        return sample
    }
}
