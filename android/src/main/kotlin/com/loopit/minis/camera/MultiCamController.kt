package com.loopit.minis.camera

import android.util.Log
import android.view.Surface
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.ConcurrentCamera
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.UseCaseGroup
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.Executors

/**
 * Front+back simultaneous capture via [ProcessCameraProvider.bindToLifecycle] with
 * concurrent camera config.
 *
 * Layout sizing is enforced by the host PlatformView (this layer just binds two
 * Preview use cases — one per [PreviewView]).
 */
object MultiCamController {
    private const val TAG = "MinisMultiCam"

    enum class Layout { TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT, SIDE_BY_SIDE }

    fun isSupported(provider: ProcessCameraProvider): Boolean =
        provider.availableConcurrentCameraInfos.isNotEmpty()

    fun layoutFromString(s: String?): Layout = when (s) {
        "topLeft" -> Layout.TOP_LEFT
        "topRight" -> Layout.TOP_RIGHT
        "bottomLeft" -> Layout.BOTTOM_LEFT
        "bottomRight" -> Layout.BOTTOM_RIGHT
        "sideBySide" -> Layout.SIDE_BY_SIDE
        else -> Layout.TOP_RIGHT
    }

    /** Tries to bind back+front simultaneously. Returns the ConcurrentCamera or null. */
    fun bind(
        provider: ProcessCameraProvider,
        owner: LifecycleOwner,
        backPreviewView: PreviewView,
        frontPreviewView: PreviewView,
    ): ConcurrentCamera? {
        val pair = provider.availableConcurrentCameraInfos.firstOrNull { infos ->
            infos.size == 2 &&
                infos.any { isBack(it) } &&
                infos.any { isFront(it) }
        } ?: return null

        val backSelector = pair.first { isBack(it) }.cameraSelector
        val frontSelector = pair.first { isFront(it) }.cameraSelector

        val backPreview = Preview.Builder().build().also {
            it.setSurfaceProvider(backPreviewView.surfaceProvider)
        }
        val frontPreview = Preview.Builder().build().also {
            it.setSurfaceProvider(frontPreviewView.surfaceProvider)
        }

        val configs = listOf(
            ConcurrentCamera.SingleCameraConfig(
                backSelector,
                UseCaseGroup.Builder().addUseCase(backPreview).build(),
                owner,
            ),
            ConcurrentCamera.SingleCameraConfig(
                frontSelector,
                UseCaseGroup.Builder().addUseCase(frontPreview).build(),
                owner,
            ),
        )

        return try {
            provider.bindToLifecycle(configs)
        } catch (e: Exception) {
            Log.w(TAG, "concurrent bind failed", e)
            null
        }
    }

    private fun isBack(info: CameraInfo): Boolean =
        info.lensFacing == CameraSelector.LENS_FACING_BACK

    private fun isFront(info: CameraInfo): Boolean =
        info.lensFacing == CameraSelector.LENS_FACING_FRONT

    /**
     * Bind both cameras with their preview output routed to two compositor
     * Surfaces. Caller supplies a compositor that has produced the two
     * input Surfaces via its [MultiCamCompositor.primaryInputSurface] /
     * [MultiCamCompositor.secondaryInputSurface].
     */
    fun bindToCompositor(
        provider: ProcessCameraProvider,
        owner: LifecycleOwner,
        primary: Surface,
        secondary: Surface,
    ): ConcurrentCamera? {
        val pair = provider.availableConcurrentCameraInfos.firstOrNull { infos ->
            infos.size == 2 &&
                infos.any { isBack(it) } &&
                infos.any { isFront(it) }
        } ?: return null
        val backSel = pair.first { isBack(it) }.cameraSelector
        val frontSel = pair.first { isFront(it) }.cameraSelector
        val exec = Executors.newSingleThreadExecutor()

        val backPreview = Preview.Builder().build().also {
            it.setSurfaceProvider(exec) { req: SurfaceRequest ->
                req.provideSurface(primary, exec) {}
            }
        }
        val frontPreview = Preview.Builder().build().also {
            it.setSurfaceProvider(exec) { req: SurfaceRequest ->
                req.provideSurface(secondary, exec) {}
            }
        }
        val cfgs = listOf(
            ConcurrentCamera.SingleCameraConfig(
                backSel,
                UseCaseGroup.Builder().addUseCase(backPreview).build(),
                owner,
            ),
            ConcurrentCamera.SingleCameraConfig(
                frontSel,
                UseCaseGroup.Builder().addUseCase(frontPreview).build(),
                owner,
            ),
        )
        return try { provider.bindToLifecycle(cfgs) }
        catch (e: Exception) { Log.w(TAG, "concurrent+compositor bind failed", e); null }
    }
}
