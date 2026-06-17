package com.loopit.minis

import android.content.Context
import android.view.View
import androidx.camera.view.PreviewView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Legacy PlatformView factory kept under viewType `minis_native_camera` for
 * backward compatibility with the existing Dart engine. The new code path
 * (`loopit/minis/camera/preview` etc.) lives in
 * [com.loopit.minis.camera.CameraPlatformViewFactory].
 */
class MinisNativeCameraPlatformViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return MinisNativeCameraPlatformView(context)
    }
}

private class MinisNativeCameraPlatformView(context: Context) : PlatformView {
    // COMPATIBLE = TextureView under the hood. PERFORMANCE (SurfaceView)
    // punches through Flutter's overlay, so capture-screen icons drawn on top
    // become invisible (the user can still tap them blindly). TextureView is
    // composited inside Flutter's surface, keeping overlay icons visible.
    private val previewView = PreviewView(context).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }

    init { MinisCameraXBridge.attachPreviewView(previewView) }

    override fun getView(): View = previewView

    override fun dispose() { MinisCameraXBridge.detachPreviewView(previewView) }
}
