package com.loopit.minis.camera

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.params.StreamConfigurationMap
import android.util.Log
import android.util.Range
import androidx.annotation.OptIn as AnnotationOptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.video.Recorder
import androidx.camera.video.VideoCapture

/**
 * High-FPS slow-motion negotiation. Picks the closest supported rate among
 * [60, 120, 240] for the active camera. Falls back to the next-lowest if the
 * exact rate isn't supported.
 */
@AnnotationOptIn(ExperimentalCamera2Interop::class)
object SlowMoController {
    private const val TAG = "MinisSlowMo"
    private val targets = intArrayOf(60, 120, 240)

    data class Result(val enabled: Boolean, val actualFps: Int)

    fun supportedRates(manager: CameraManager, cameraId: String): List<Int> {
        return try {
            val chars = manager.getCameraCharacteristics(cameraId)
            val ranges: Array<Range<Int>>? =
                chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            val streamMap: StreamConfigurationMap? =
                chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val highSpeed: Array<Range<Int>>? = streamMap?.highSpeedVideoFpsRanges
            val all = mutableSetOf<Int>()
            ranges?.forEach { all.add(it.upper) }
            highSpeed?.forEach { all.add(it.upper) }
            targets.filter { all.contains(it) }
        } catch (e: Exception) {
            Log.w(TAG, "supportedRates: ${e.message}")
            emptyList()
        }
    }

    fun negotiate(requested: Int, supported: List<Int>): Int {
        if (supported.contains(requested)) return requested
        return supported.lastOrNull { it <= requested } ?: 0
    }

    fun applyTo(builder: VideoCapture.Builder<Recorder>, fps: Int) {
        if (fps <= 30) return
        val ext = Camera2Interop.Extender(builder)
        ext.setCaptureRequestOption(
            android.hardware.camera2.CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
            Range(fps, fps),
        )
    }

    fun readCameraId(camera: Camera): String? =
        try { Camera2CameraInfo.from(camera.cameraInfo).cameraId } catch (_: Exception) { null }
}
