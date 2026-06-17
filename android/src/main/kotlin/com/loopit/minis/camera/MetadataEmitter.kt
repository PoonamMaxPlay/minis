package com.loopit.minis.camera

import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.RggbChannelVector
import androidx.annotation.OptIn as AnnotationOptIn
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.ExtendableBuilder
import java.util.concurrent.atomic.AtomicLong

/**
 * Reads per-frame metadata from CaptureResult and forwards to a listener at
 * most every [minIntervalMs] (30 Hz default).
 */
@AnnotationOptIn(ExperimentalCamera2Interop::class)
class MetadataEmitter(
    private val minIntervalMs: Long = 33,
    private val listener: CameraXEngine.MetadataListener?,
) : CameraCaptureSession.CaptureCallback() {

    private val lastEmit = AtomicLong(0)

    override fun onCaptureCompleted(
        session: CameraCaptureSession,
        request: CaptureRequest,
        result: TotalCaptureResult,
    ) {
        val now = System.currentTimeMillis()
        val prev = lastEmit.get()
        if (now - prev < minIntervalMs) return
        if (!lastEmit.compareAndSet(prev, now)) return

        val iso = result.get(CaptureResult.SENSOR_SENSITIVITY)
        val shutter = result.get(CaptureResult.SENSOR_EXPOSURE_TIME)
        val focus = result.get(CaptureResult.LENS_FOCUS_DISTANCE)
        val gains: RggbChannelVector? = result.get(CaptureResult.COLOR_CORRECTION_GAINS)
        val wbKelvin = gains?.let { gainsToKelvin(it) }
        val evIdx = result.get(CaptureResult.CONTROL_AE_EXPOSURE_COMPENSATION) ?: 0

        listener?.onMetadata(
            iso = iso,
            shutterNs = shutter,
            evIndex = evIdx,
            focus = focus,
            wbKelvin = wbKelvin,
            lensRatio = null,
        )
    }

    /** Crude inverse of [ManualControls.kelvinToGains]; binary-search 2000..10000K. */
    private fun gainsToKelvin(g: RggbChannelVector): Int {
        // We map back from R/B gain ratio. Higher R gain = cooler scene → higher Kelvin
        // (because the camera amplifies red to balance a blue-shifted source).
        val r = if (g.red > 0) (1.0 / g.red) else 0.0
        val b = if (g.blue > 0) (1.0 / g.blue) else 0.0
        if (r <= 0 || b <= 0) return 5500
        val ratio = r / b
        // Linear regression fit: kelvin ≈ 2000 + 6000*ratio (clamped). Cheap; not WB-exact.
        return (2000 + (ratio * 6000.0).coerceIn(0.0, 8000.0)).toInt().coerceIn(2000, 10000)
    }

    fun <T> attachTo(builder: ExtendableBuilder<T>) {
        Camera2Interop.Extender(builder).setSessionCaptureCallback(this)
    }
}
