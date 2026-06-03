package com.loopit.minis.camera

import android.content.Context
import android.util.Log
import androidx.annotation.OptIn as AnnotationOptIn
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.DynamicRange
import androidx.camera.core.ExperimentalImageCaptureOutputFormat
import androidx.camera.core.ImageCapture
import androidx.camera.extensions.ExtensionMode
import androidx.camera.extensions.ExtensionsManager
import androidx.camera.lifecycle.ProcessCameraProvider
import com.google.common.util.concurrent.ListenableFuture
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Wraps CameraXExtensions HDR + 10-bit `DynamicRange.HDR_UNSPECIFIED_10_BIT`.
 *
 * Selector returned from [hdrSelector] should be passed to
 * `ProcessCameraProvider.bindToLifecycle` instead of the base [CameraSelector].
 */
class HdrController {
    private val enabled = AtomicBoolean(false)
    private var extensionsManager: ExtensionsManager? = null

    fun isEnabled(): Boolean = enabled.get()

    fun initialize(context: Context, provider: ProcessCameraProvider): ListenableFuture<ExtensionsManager> {
        val f = ExtensionsManager.getInstanceAsync(context, provider)
        f.addListener({
            try { extensionsManager = f.get() } catch (e: Exception) { Log.w(TAG, "ext init", e) }
        }, Runnable::run)
        return f
    }

    fun isHdrSupported(base: CameraSelector): Boolean {
        val mgr = extensionsManager ?: return false
        return runCatching { mgr.isExtensionAvailable(base, ExtensionMode.HDR) }.getOrDefault(false)
    }

    fun hdrSelector(base: CameraSelector): CameraSelector {
        val mgr = extensionsManager ?: return base
        return runCatching { mgr.getExtensionEnabledCameraSelector(base, ExtensionMode.HDR) }
            .getOrDefault(base)
    }

    fun setEnabled(on: Boolean) {
        enabled.set(on)
    }

    /** Returns HDR_UNSPECIFIED_10_BIT when enabled, else SDR. */
    fun dynamicRange(): DynamicRange =
        if (enabled.get()) DynamicRange.HDR_UNSPECIFIED_10_BIT else DynamicRange.SDR

    /** RAW output not supported on the active CameraX version; JPEG only. */
    fun configurePhotoFormat(
        builder: ImageCapture.Builder,
        info: CameraInfo,
        raw: Boolean,
    ): Boolean {
        return !raw
    }

    companion object { private const val TAG = "MinisHdrController" }
}
