package com.loopit.minis.camera

import android.graphics.ImageFormat
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

/**
 * ImageAnalysis.Analyzer that converts NV21 / YUV_420_888 frames into RGBA via
 * [NativePipeline] (or a Java fallback) and forwards them to [sink].
 *
 * Throttled to [minIntervalMs] (default ~42 ms / 24 Hz) to keep IPC overhead
 * tolerable. The bytes argument is the backing array of a direct buffer the
 * caller may not retain past the sink call.
 */
class FrameStreamer(
    private val minIntervalMs: Long = 42,
    private val sink: Sink,
) : ImageAnalysis.Analyzer {

    fun interface Sink {
        fun onFrame(width: Int, height: Int, rgbaBytes: ByteArray)
    }

    private val lastEmit = AtomicLong(0)
    private var dst: ByteBuffer? = null

    override fun analyze(proxy: ImageProxy) {
        val now = System.currentTimeMillis()
        if (now - lastEmit.get() < minIntervalMs) { proxy.close(); return }
        try {
            val w = proxy.width
            val h = proxy.height
            val planes = proxy.planes
            if (planes.size < 3) return
            val ySize = w * h
            val dstStride = w * 4
            val needed = h * dstStride
            var d = dst
            if (d == null || d.capacity() < needed) {
                d = ByteBuffer.allocateDirect(needed)
                dst = d
            } else { d.clear() }

            if (NativePipeline.available) {
                // Build NV21 layout from YUV_420_888: V plane interleaved with U.
                // For YUV_420_888 from CameraX (typical 4:2:0), the U & V planes
                // arrive on separate buffers; we hand them to i420ToRgba directly.
                NativePipeline.i420ToRgba(
                    planes[0].buffer, planes[0].rowStride,
                    planes[1].buffer, planes[1].rowStride,
                    planes[2].buffer, planes[2].rowStride,
                    d, dstStride, w, h,
                )
            } else {
                javaI420ToRgba(planes, d, w, h, dstStride)
            }
            val bytes = ByteArray(needed)
            d.rewind()
            d.get(bytes)
            lastEmit.set(now)
            sink.onFrame(w, h, bytes)
        } finally {
            proxy.close()
        }
    }

    /** Reference Java BT.601 conversion used when libminis_camera_pipeline.so is missing. */
    private fun javaI420ToRgba(
        planes: Array<ImageProxy.PlaneProxy>,
        dst: ByteBuffer, w: Int, h: Int, dstStride: Int,
    ) {
        val y = planes[0].buffer
        val u = planes[1].buffer
        val v = planes[2].buffer
        val yStride = planes[0].rowStride
        val uStride = planes[1].rowStride
        val vStride = planes[2].rowStride
        val uPixel = planes[1].pixelStride
        val vPixel = planes[2].pixelStride
        val out = ByteArray(dstStride)
        val yRow = ByteArray(yStride)
        val uRow = ByteArray(uStride)
        val vRow = ByteArray(vStride)
        y.rewind(); u.rewind(); v.rewind()
        for (row in 0 until h) {
            y.position(row * yStride)
            y.get(yRow, 0, yStride.coerceAtMost(yRow.size))
            if (row % 2 == 0) {
                u.position((row / 2) * uStride)
                u.get(uRow, 0, uStride.coerceAtMost(uRow.size))
                v.position((row / 2) * vStride)
                v.get(vRow, 0, vStride.coerceAtMost(vRow.size))
            }
            for (col in 0 until w) {
                val yi = yRow[col].toInt() and 0xFF
                val ui = uRow[(col / 2) * uPixel].toInt() and 0xFF
                val vi = vRow[(col / 2) * vPixel].toInt() and 0xFF
                val c = yi - 16
                val d = ui - 128
                val e = vi - 128
                val r = (298 * c + 409 * e + 128) shr 8
                val g = (298 * c - 100 * d - 208 * e + 128) shr 8
                val b = (298 * c + 516 * d + 128) shr 8
                out[col * 4 + 0] = clampByte(r)
                out[col * 4 + 1] = clampByte(g)
                out[col * 4 + 2] = clampByte(b)
                out[col * 4 + 3] = 255.toByte()
            }
            dst.position(row * dstStride)
            dst.put(out, 0, dstStride)
        }
    }

    private fun clampByte(v: Int): Byte = when {
        v < 0 -> 0
        v > 255 -> 255.toByte()
        else -> v.toByte()
    }
}
