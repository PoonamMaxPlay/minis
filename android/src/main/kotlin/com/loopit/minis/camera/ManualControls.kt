package com.loopit.minis.camera

import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.util.Log
import android.util.Range
import androidx.annotation.OptIn as AnnotationOptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.ExtendableBuilder

/**
 * Wraps Camera2Interop reach-throughs for ISO, shutter, AWB, AF on top of CameraX.
 */
@AnnotationOptIn(ExperimentalCamera2Interop::class)
object ManualControls {
    private const val TAG = "MinisManualControls"

    /** Apply persistent manual params to any [ExtendableBuilder]-style use case. */
    fun <T> applyTo(
        builder: ExtendableBuilder<T>,
        iso: Int?,
        shutterNs: Long?,
        wbKelvin: Int?,
        lensPosition: Float?,
    ) {
        val ext = Camera2Interop.Extender(builder)
        if (iso != null) {
            ext.setCaptureRequestOption(CaptureRequest.SENSOR_SENSITIVITY, iso)
            ext.setCaptureRequestOption(
                CaptureRequest.CONTROL_AE_MODE,
                android.hardware.camera2.CameraMetadata.CONTROL_AE_MODE_OFF,
            )
        }
        if (shutterNs != null) {
            ext.setCaptureRequestOption(CaptureRequest.SENSOR_EXPOSURE_TIME, shutterNs)
        }
        if (wbKelvin != null) {
            ext.setCaptureRequestOption(
                CaptureRequest.CONTROL_AWB_MODE,
                android.hardware.camera2.CameraMetadata.CONTROL_AWB_MODE_OFF,
            )
            val g = kelvinToGains(wbKelvin)
            ext.setCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_GAINS, g)
        }
        if (lensPosition != null) {
            ext.setCaptureRequestOption(
                CaptureRequest.CONTROL_AF_MODE,
                android.hardware.camera2.CameraMetadata.CONTROL_AF_MODE_OFF,
            )
            ext.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, lensPosition)
        }
    }

    fun applyExposureBias(camera: Camera, ev: Float) {
        try {
            camera.cameraControl.setExposureCompensationIndex(ev.toInt())
        } catch (e: Exception) {
            Log.w(TAG, "exposureBias: ${e.message}")
        }
    }

    fun readRanges(manager: CameraManager, cameraId: String): ManualRanges {
        return try {
            val chars = manager.getCameraCharacteristics(cameraId)
            val isoRange: Range<Int>? = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
            val shutterRange: Range<Long>? = chars.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
            ManualRanges(
                minIso = isoRange?.lower,
                maxIso = isoRange?.upper,
                minShutterNs = shutterRange?.lower,
                maxShutterNs = shutterRange?.upper,
            )
        } catch (e: Exception) {
            Log.w(TAG, "readRanges: ${e.message}")
            ManualRanges()
        }
    }

    fun readPrimaryCameraId(camera: Camera): String? {
        return try {
            Camera2CameraInfo.from(camera.cameraInfo).cameraId
        } catch (e: Exception) {
            Log.w(TAG, "readPrimaryCameraId: ${e.message}")
            null
        }
    }

    /**
     * Crude kelvin → R/G/B gains (D65 baseline). Real production code should
     * resolve against the per-device color-correction matrix; this gets us
     * the visible shift without a third-party color science lib.
     */
    private fun kelvinToGains(kelvin: Int): android.hardware.camera2.params.RggbChannelVector {
        val temp = (kelvin.coerceIn(2000, 10000)) / 100.0
        val r: Double
        val g: Double
        val b: Double
        if (temp <= 66) {
            r = 1.0
            g = (99.4708025861 * Math.log(temp) - 161.1195681661).coerceIn(0.0, 255.0) / 255.0
            b = if (temp <= 19) 0.0
            else (138.5177312231 * Math.log(temp - 10) - 305.0447927307).coerceIn(0.0, 255.0) / 255.0
        } else {
            r = (329.698727446 * Math.pow(temp - 60.0, -0.1332047592)).coerceIn(0.0, 255.0) / 255.0
            g = (288.1221695283 * Math.pow(temp - 60.0, -0.0755148492)).coerceIn(0.0, 255.0) / 255.0
            b = 1.0
        }
        val rg = (1.0 / r).coerceAtLeast(0.1).toFloat()
        val gg = (1.0 / g).coerceAtLeast(0.1).toFloat()
        val bg = (1.0 / b).coerceAtLeast(0.1).toFloat()
        return android.hardware.camera2.params.RggbChannelVector(rg, gg, gg, bg)
    }

    data class ManualRanges(
        val minIso: Int? = null,
        val maxIso: Int? = null,
        val minShutterNs: Long? = null,
        val maxShutterNs: Long? = null,
    )
}
