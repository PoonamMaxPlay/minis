package com.loopit.minis

import android.content.Context
import android.view.View
import androidx.camera.view.PreviewView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Embeds CameraX [PreviewView] inside Flutter for native Minis camera preview.
 */
class MinisNativeCameraPlatformViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return MinisNativeCameraPlatformView(context)
    }
}

private class MinisNativeCameraPlatformView(context: Context) : PlatformView {
    private val previewView = PreviewView(context)

    init {
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        previewView.scaleType = PreviewView.ScaleType.FILL_CENTER
        MinisCameraXBridge.attachPreviewView(previewView)
    }

    override fun getView(): View = previewView

    override fun dispose() {
        MinisCameraXBridge.detachPreviewView(previewView)
    }
}
