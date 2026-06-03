package com.loopit.minis.camera

import android.util.Log
import java.nio.ByteBuffer

/**
 * JNI bridge to `libminis_camera_pipeline.so` for YUV → RGBA conversion on
 * ImageAnalysis frames. The library is loaded lazily on first use; if loading
 * fails (NDK not configured for this build), callers should fall back to a
 * Java-side conversion.
 */
object NativePipeline {
    private const val TAG = "MinisNativePipeline"

    @Volatile var available: Boolean = false
        private set

    init {
        try {
            System.loadLibrary("minis_camera_pipeline")
            available = true
        } catch (t: Throwable) {
            Log.w(TAG, "native pipeline unavailable: ${t.message}")
            available = false
        }
    }

    @JvmStatic external fun nv21ToRgba(
        yBuf: ByteBuffer, yStride: Int,
        vuBuf: ByteBuffer, vuStride: Int,
        dstBuf: ByteBuffer, dstStride: Int,
        width: Int, height: Int,
    )

    @JvmStatic external fun i420ToRgba(
        yBuf: ByteBuffer, yStride: Int,
        uBuf: ByteBuffer, uStride: Int,
        vBuf: ByteBuffer, vStride: Int,
        dstBuf: ByteBuffer, dstStride: Int,
        width: Int, height: Int,
    )
}
