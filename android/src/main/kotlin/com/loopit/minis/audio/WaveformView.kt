package com.loopit.minis.audio

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import kotlin.math.max
import kotlin.math.min

/**
 * Renders peaks[] as vertical bars, with a progress overlay split. Live mode
 * appends a fresh peak per tick from the levels stream and scrolls left.
 *
 * Args (creationParams):
 *  - peaks: List<Double> | DoubleArray
 *  - rms: List<Double> (optional)
 *  - color: ARGB int  (default 0xFFFFFFFF)
 *  - bgColor: ARGB int (default 0x00000000)
 *  - progressColor: ARGB int (default 0xFFFF3366)
 *  - progressMs: int
 *  - durationMs: int
 *  - barWidthDp / barGapDp: double (default 2.0 / 1.5)
 *  - mode: "static" | "live"
 */
class WaveformViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val map = (args as? Map<String, Any?>) ?: emptyMap()
        return WaveformPlatformView(context, messenger, viewId, map)
    }
}

private class WaveformPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    args: Map<String, Any?>,
) : PlatformView {
    private val view = WaveformDrawable(context)
    private val channel = MethodChannel(messenger, "loopit/minis/audio/waveform/$viewId")
    private val handler = Handler(Looper.getMainLooper())
    private var levelsSub: EventChannel.StreamHandler? = null

    init {
        applyArgs(args)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    @Suppress("UNCHECKED_CAST")
                    val m = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                    handler.post { applyArgs(m) }
                    result.success(null)
                }
                "appendLive" -> {
                    val p = (call.arguments as? Number)?.toDouble() ?: 0.0
                    handler.post { view.pushLive(p) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun applyArgs(m: Map<String, Any?>) {
        val peaks = (m["peaks"] as? List<*>)?.mapNotNull { (it as? Number)?.toDouble() }
        if (peaks != null) view.peaks = peaks.toDoubleArray()
        (m["color"] as? Number)?.let { view.barColor = it.toInt() }
        (m["bgColor"] as? Number)?.let { view.bgColor = it.toInt() }
        (m["progressColor"] as? Number)?.let { view.progressColor = it.toInt() }
        (m["progressMs"] as? Number)?.let { view.progressMs = it.toInt() }
        (m["durationMs"] as? Number)?.let { view.durationMs = it.toInt() }
        (m["barWidthDp"] as? Number)?.let { view.barWidthDp = it.toFloat() }
        (m["barGapDp"] as? Number)?.let { view.barGapDp = it.toFloat() }
        (m["mode"] as? String)?.let { view.live = it == "live" }
        view.invalidate()
    }

    override fun getView(): View = view

    override fun dispose() {
        channel.setMethodCallHandler(null)
        levelsSub = null
    }
}

private class WaveformDrawable(context: Context) : View(context) {
    var peaks: DoubleArray = DoubleArray(0)
    var live: Boolean = false
    var barColor: Int = Color.WHITE
    var bgColor: Int = Color.TRANSPARENT
    var progressColor: Int = 0xFFFF3366.toInt()
    var progressMs: Int = 0
    var durationMs: Int = 0
    var barWidthDp: Float = 2.0f
    var barGapDp: Float = 1.5f

    private val livePeaks: ArrayDeque<Double> = ArrayDeque()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val density = context.resources.displayMetrics.density

    fun pushLive(p: Double) {
        livePeaks.addLast(p.coerceIn(0.0, 1.0))
        val maxBars = (width / max(1f, (barWidthDp + barGapDp) * density)).toInt()
        while (livePeaks.size > maxBars && maxBars > 0) livePeaks.removeFirst()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (bgColor != Color.TRANSPARENT) {
            paint.color = bgColor
            paint.style = Paint.Style.FILL
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
        }
        val barW = max(1f, barWidthDp * density)
        val gap = max(0f, barGapDp * density)
        val step = barW + gap
        val barCount = max(1, (width / step).toInt())
        val data = if (live) livePeaks.toDoubleArray() else peaks
        if (data.isEmpty()) return
        val midY = height / 2f
        val progressFrac =
            if (durationMs > 0) progressMs.coerceIn(0, durationMs).toFloat() / durationMs.toFloat()
            else 0f
        val progressBar = (barCount * progressFrac).toInt()
        paint.style = Paint.Style.FILL
        for (i in 0 until barCount) {
            val srcIdx = min(data.size - 1, (i.toLong() * data.size / barCount).toInt())
            val mag = data[srcIdx].coerceIn(0.0, 1.0).toFloat()
            val h = mag * height * 0.5f
            val x = i * step
            paint.color = if (i < progressBar) progressColor else barColor
            canvas.drawRect(x, midY - h, x + barW, midY + h, paint)
        }
    }

    @Suppress("unused")
    fun dpToPx(value: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics)
}
