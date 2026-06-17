package com.loopit.minis.imgedit

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import kotlin.math.hypot
import kotlin.math.max

/**
 * Per-`DrawLayer` raster cache. Strokes are stamped into a [Bitmap] at
 * base-image resolution and later uploaded as an OpenGL/Metal texture by
 * the host renderer. Eraser uses [PorterDuff.Mode.CLEAR].
 *
 * Stamping math mirrors `improvement2.md` B6: radial-falloff stamped
 * quads at `size/4` spacing, alpha = `(1 - smoothstep(hardness, 1, d/r)) * pressure`.
 */
class DrawLayer(width: Int, height: Int) {

    private val bitmap: Bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    private val canvas: Canvas = Canvas(bitmap)
    private val paint: Paint = Paint(Paint.ANTI_ALIAS_FLAG)

    fun stroke(
        points: List<Map<String, Any?>>,
        color: Int,
        size: Float,
        hardness: Float,
        eraser: Boolean,
    ) {
        paint.color = color
        if (eraser) paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
        else paint.xfermode = null
        paint.style = Paint.Style.FILL
        val radius = max(1f, size * 0.5f)
        val blur = max(0.1f, (1f - hardness) * radius)
        paint.maskFilter = BlurMaskFilter(blur, BlurMaskFilter.Blur.NORMAL)

        val spacing = max(1f, size * 0.25f)
        for (i in 0 until points.size - 1) {
            val a = points[i]
            val b = points[i + 1]
            val ax = (a["x"] as? Number)?.toFloat() ?: continue
            val ay = (a["y"] as? Number)?.toFloat() ?: continue
            val bx = (b["x"] as? Number)?.toFloat() ?: continue
            val by = (b["y"] as? Number)?.toFloat() ?: continue
            val pressureA = (a["pressure"] as? Number)?.toFloat() ?: 1f
            val pressureB = (b["pressure"] as? Number)?.toFloat() ?: 1f
            val dist = hypot(bx - ax, by - ay)
            val steps = max(1, (dist / spacing).toInt())
            for (s in 0..steps) {
                val t = s / steps.toFloat()
                val x = ax + (bx - ax) * t
                val y = ay + (by - ay) * t
                val pr = pressureA + (pressureB - pressureA) * t
                paint.alpha = (Color.alpha(color) * pr.coerceIn(0f, 1f)).toInt()
                canvas.drawCircle(x, y, radius, paint)
            }
        }
        paint.xfermode = null
        paint.maskFilter = null
    }

    fun snapshot(): Bitmap = bitmap
}
