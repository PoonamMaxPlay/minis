package com.loopit.minis.imgedit

import android.graphics.Bitmap
import android.view.Surface

/**
 * JNI surface for the C++ pipeline under `cpp/imgedit/`.
 *
 * The native library is built via the host app's NDK toolchain (the plugin
 * does not currently force-build C++ — adding `externalNativeBuild` here
 * would conflict with the camera-only build). The header at
 * `cpp/imgedit/pipeline.h` declares the JNI symbols the C++ side exports
 * when the host opts in via its own `CMakeLists.txt`.
 *
 * Until the native library is loaded all methods are safe no-ops: every
 * call routes through [safe] which catches `UnsatisfiedLinkError` so the
 * Dart-facing API stays unbroken during the skeleton phase.
 */
object ImageEditNative {
    private var libraryLoaded: Boolean = false

    init {
        libraryLoaded = try {
            System.loadLibrary("minis_imgedit")
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun initSession(viewId: Int, sourcePath: String?, w: Int, h: Int) =
        safe { nativeInitSession(viewId, sourcePath ?: "", w, h) }

    fun disposeView(viewId: Int) = safe { nativeDisposeView(viewId) }

    fun surfaceCreated(viewId: Int, surface: Surface) =
        safe { nativeSurfaceCreated(viewId, surface) }

    fun surfaceChanged(viewId: Int, w: Int, h: Int) =
        safe { nativeSurfaceChanged(viewId, w, h) }

    fun surfaceDestroyed(viewId: Int) =
        safe { nativeSurfaceDestroyed(viewId) }

    fun requestRender(viewId: Int) = safe { nativeRequestRender(viewId) }

    fun applyAdjust(viewId: Int, key: String, value: Double) =
        safe { nativeApplyAdjust(viewId, key, value) }

    fun applyFilter(viewId: Int, lutPath: String, intensity: Double) =
        safe { nativeApplyFilter(viewId, lutPath, intensity) }

    fun applyCrop(
        viewId: Int,
        rect: Map<String, Any?>,
        rotationDeg: Double,
        persp: List<Double>?,
    ) = safe { nativeApplyCrop(viewId, rect, rotationDeg, persp ?: emptyList()) }

    fun brushStroke(viewId: Int, args: Map<*, *>) =
        safe { nativeBrushStroke(viewId, args) }

    fun spotHeal(viewId: Int, args: Map<*, *>) =
        safe { nativeSpotHeal(viewId, args) }

    fun liquify(viewId: Int, args: Map<*, *>) =
        safe { nativeLiquify(viewId, args) }

    fun beautify(viewId: Int, args: Map<*, *>) =
        safe { nativeBeautify(viewId, args) }

    fun readPixels(viewId: Int): Bitmap? =
        safeOr(null) { nativeReadPixels(viewId) }

    fun runFaceLandmarks(viewId: Int, sourcePath: String, detector: Any): List<Map<String, Any?>> =
        safeOr(emptyList()) { nativeRunFaceLandmarks(viewId, sourcePath, detector) }

    fun runSelfieSegmentation(viewId: Int, sourcePath: String, segmenter: Any): Map<String, Any?> =
        safeOr(mapOf("status" to "skipped")) { nativeRunSelfieSegmentation(viewId, sourcePath, segmenter) }

    private inline fun safe(block: () -> Unit) {
        if (!libraryLoaded) return
        try {
            block()
        } catch (_: UnsatisfiedLinkError) {
            libraryLoaded = false
        } catch (_: Throwable) {
            // swallow — engine continues with last good state
        }
    }

    private inline fun <T> safeOr(default: T, block: () -> T): T {
        if (!libraryLoaded) return default
        return try {
            block()
        } catch (_: UnsatisfiedLinkError) {
            libraryLoaded = false
            default
        } catch (_: Throwable) {
            default
        }
    }

    private external fun nativeInitSession(viewId: Int, sourcePath: String, w: Int, h: Int)
    private external fun nativeDisposeView(viewId: Int)
    private external fun nativeSurfaceCreated(viewId: Int, surface: Surface)
    private external fun nativeSurfaceChanged(viewId: Int, w: Int, h: Int)
    private external fun nativeSurfaceDestroyed(viewId: Int)
    private external fun nativeRequestRender(viewId: Int)
    private external fun nativeApplyAdjust(viewId: Int, key: String, value: Double)
    private external fun nativeApplyFilter(viewId: Int, lutPath: String, intensity: Double)
    private external fun nativeApplyCrop(viewId: Int, rect: Map<String, Any?>, rotationDeg: Double, persp: List<Double>)
    private external fun nativeBrushStroke(viewId: Int, args: Map<*, *>)
    private external fun nativeSpotHeal(viewId: Int, args: Map<*, *>)
    private external fun nativeLiquify(viewId: Int, args: Map<*, *>)
    private external fun nativeBeautify(viewId: Int, args: Map<*, *>)
    private external fun nativeReadPixels(viewId: Int): Bitmap?
    private external fun nativeRunFaceLandmarks(viewId: Int, sourcePath: String, detector: Any): List<Map<String, Any?>>
    private external fun nativeRunSelfieSegmentation(viewId: Int, sourcePath: String, segmenter: Any): Map<String, Any?>
}
