package com.loopit.minis.imgedit

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import java.io.File

/**
 * CPU rasterizer for sticker / text / emoji layers. Each `paint*` writes
 * into a transparent base bitmap at canvas resolution; the renderer
 * uploads the result as a layer texture in the render graph.
 */
object StickerLayer {

    fun paintSticker(canvasW: Int, canvasH: Int,
                     stickerPath: String,
                     transform: List<Double>?): Bitmap? {
        if (canvasW <= 0 || canvasH <= 0) return null
        val f = File(stickerPath)
        if (!f.exists()) return null
        val src = BitmapFactory.decodeFile(stickerPath) ?: return null
        val out = Bitmap.createBitmap(canvasW, canvasH, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val m = matrixOf(transform, canvasW, canvasH)
        c.drawBitmap(src, m, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
        return out
    }

    fun paintText(canvasW: Int, canvasH: Int,
                  text: String, fontFamily: String?, sizePx: Float,
                  color: Int, transform: List<Double>?,
                  strokeColor: Int? = null, strokeWidth: Float = 0f): Bitmap? {
        if (canvasW <= 0 || canvasH <= 0) return null
        val out = Bitmap.createBitmap(canvasW, canvasH, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = sizePx
            typeface = if (!fontFamily.isNullOrEmpty()) {
                try { Typeface.create(fontFamily, Typeface.NORMAL) } catch (_: Throwable) { Typeface.DEFAULT }
            } else Typeface.DEFAULT
        }
        val bounds = android.graphics.Rect()
        paint.getTextBounds(text, 0, text.length, bounds)
        val cx = canvasW / 2f
        val cy = canvasH / 2f
        val m = matrixOf(transform, canvasW, canvasH)
        c.save()
        c.concat(m)
        c.translate(-bounds.width() / 2f, bounds.height() / 2f)
        if (strokeColor != null && strokeWidth > 0f) {
            val sp = Paint(paint).apply {
                style = Paint.Style.STROKE
                this.strokeWidth = strokeWidth
                this.color = strokeColor
            }
            c.drawText(text, cx, cy, sp)
        }
        paint.color = color
        paint.style = Paint.Style.FILL
        c.drawText(text, cx, cy, paint)
        c.restore()
        return out
    }

    fun paintEmoji(canvasW: Int, canvasH: Int,
                   codePoint: Int, sizePx: Float,
                   transform: List<Double>?): Bitmap? {
        val s = String(Character.toChars(codePoint))
        return paintText(canvasW, canvasH, s, null, sizePx, Color.WHITE, transform)
    }

    private fun matrixOf(transform: List<Double>?, canvasW: Int, canvasH: Int): Matrix {
        val m = Matrix()
        if (transform != null && transform.size >= 6) {
            // affine[6]: tx, ty, sx, sy, rotDeg, skew
            val tx = transform[0].toFloat()
            val ty = transform[1].toFloat()
            val sx = transform[2].toFloat()
            val sy = transform[3].toFloat()
            val rot = transform[4].toFloat()
            val skew = if (transform.size > 5) transform[5].toFloat() else 0f
            m.postScale(sx, sy)
            m.postSkew(skew, 0f)
            m.postRotate(rot, 0f, 0f)
            m.postTranslate(tx * canvasW, ty * canvasH)
        } else {
            m.postTranslate(canvasW / 2f, canvasH / 2f)
        }
        return m
    }
}
