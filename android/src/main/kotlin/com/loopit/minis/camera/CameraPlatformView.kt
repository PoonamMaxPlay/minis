package com.loopit.minis.camera

import android.content.Context
import android.view.View
import androidx.camera.view.PreviewView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Hosts a CameraX [PreviewView] for the Flutter side. Two factory IDs:
 *   - primary preview (default): `loopit/minis/camera/preview`
 *   - secondary (multi-cam PiP): `loopit/minis/camera/preview_secondary`
 *
 * Also kept under the legacy ID `minis_native_camera` for backward compat with
 * the existing Dart `AndroidView(viewType: 'minis_native_camera')` calls.
 */
class CameraPlatformViewFactory(
    private val engine: CameraXEngine,
    private val secondary: Boolean = false,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return CameraPlatformView(context, engine, secondary)
    }
}

private class CameraPlatformView(
    context: Context,
    private val engine: CameraXEngine,
    private val secondary: Boolean,
) : PlatformView {
    // COMPATIBLE = TextureView so Flutter can composite overlay widgets on top
    // of the preview; PERFORMANCE uses a SurfaceView that punches through and
    // hides UI elements drawn above it.
    private val previewView = PreviewView(context).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }

    init {
        if (secondary) engine.attachSecondaryPreview(previewView)
        else engine.attachPrimaryPreview(previewView)
    }

    override fun getView(): View = previewView

    override fun dispose() {
        if (secondary) engine.attachSecondaryPreview(null)
        else engine.detachPrimaryPreview(previewView)
    }
}
