package com.loopit.minis.imgedit

import android.content.Context
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * `loopit/minis/imgedit/canvas` factory. Each PlatformView owns its own
 * [ImageEditEngine] bound to a single Flutter viewId; the engine drives a
 * GLES 3 [SurfaceView] (the renderer in `cpp/imgedit/` handles HW-canvas
 * fallback when EGL is unavailable).
 */
class ImageEditPlatformViewFactory(
    @Suppress("unused") private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = (args as? Map<String, Any?>) ?: emptyMap()
        val sourcePath = params["sourcePath"] as? String
        return ImageEditPlatformView(context, viewId, sourcePath)
    }
}

private class ImageEditPlatformView(
    context: Context,
    viewId: Int,
    sourcePath: String?,
) : PlatformView {

    private val surfaceView = SurfaceView(context)
    private val engine: ImageEditEngine =
        ImageEditEngine.create(viewId, surfaceView, sourcePath).also {
            ImageEditPluginRouter.register(it)
        }

    override fun getView(): View = surfaceView

    override fun dispose() {
        engine.detach()
    }
}
