package com.loopit.minis.camera

import androidx.camera.core.CameraInfo
import androidx.camera.core.ImageCapture

/**
 * Helpers for CameraX still capture. RAW (DNG) output disabled — the active
 * camera-core version does not expose `OUTPUT_FORMAT_RAW`.
 */
object RawCapture {
    fun isRawSupported(info: CameraInfo): Boolean = false

    fun build(raw: Boolean): ImageCapture {
        return ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
            .build()
    }
}
