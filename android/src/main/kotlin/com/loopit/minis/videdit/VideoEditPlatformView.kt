package com.loopit.minis.videdit

import android.content.Context
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * `PlatformView` hosting a [TextureView] that the GL compositor renders into.
 *
 * When the SurfaceTexture becomes available we publish it through the same
 * MethodChannel the [VideoEditEngine] listens on, so the native compositor
 * can attach an EGL surface and start drawing. The render thread is owned
 * by the compositor (`gl_compositor.cpp`); this class only manages the
 * lifecycle of the surface.
 */
class VideoEditPlatformView(
    context: Context,
    viewId: Int,
    args: Map<String, Any?>?,
    private val messenger: BinaryMessenger,
) : PlatformView {

  private val texture = TextureView(context).apply {
    isOpaque = true
    setBackgroundColor(Color.BLACK)
  }
  private val notifyChannel = MethodChannel(messenger, "loopit/minis/videdit")
  private var surface: Surface? = null

  init {
    texture.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
      override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
        st.setDefaultBufferSize(w, h)
        val s = Surface(st)
        surface = s
        notifySurface(viewId, s, w, h)
      }

      override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) {
        st.setDefaultBufferSize(w, h)
        notifyResize(viewId, w, h)
      }

      override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
        notifyDetach(viewId)
        surface?.release()
        surface = null
        return true
      }

      override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
    }
  }

  private fun notifySurface(viewId: Int, surface: Surface, w: Int, h: Int) {
    notifyChannel.invokeMethod(
      "previewSurfaceAttached",
      mapOf("viewId" to viewId, "width" to w, "height" to h),
    )
    VideoEditNativePreview.attach(viewId, surface, w, h)
  }

  private fun notifyResize(viewId: Int, w: Int, h: Int) {
    VideoEditNativePreview.resize(viewId, w, h)
  }

  private fun notifyDetach(viewId: Int) {
    VideoEditNativePreview.detach(viewId)
  }

  override fun getView(): View = texture
  override fun dispose() {
    surface?.release()
    surface = null
  }
}

class VideoEditPlatformViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, id: Int, args: Any?): PlatformView {
    @Suppress("UNCHECKED_CAST")
    return VideoEditPlatformView(context, id, args as? Map<String, Any?>, messenger)
  }
}

/**
 * Thin façade around the JNI compositor binding. Loads `libminis_videdit.so`
 * lazily and silently no-ops if the engine isn't available (clean checkout
 * before the FFmpeg build runs).
 */
object VideoEditNativePreview {

  @Volatile private var loaded = false
  private fun ensure(): Boolean {
    if (loaded) return true
    return try {
      System.loadLibrary("minis_videdit")
      loaded = true
      true
    } catch (_: Throwable) {
      false
    }
  }

  fun attach(viewId: Int, surface: Surface, w: Int, h: Int) {
    if (!ensure()) return
    runCatching { nativeAttachSurface(viewId.toLong(), surface, w, h) }
  }

  fun resize(viewId: Int, w: Int, h: Int) {
    if (!ensure()) return
    runCatching { nativeResizeSurface(viewId.toLong(), w, h) }
  }

  fun detach(viewId: Int) {
    if (!ensure()) return
    runCatching { nativeDetachSurface(viewId.toLong()) }
  }

  /**
   * Push an OES external texture name (the one HWDecoderPool's
   * `SurfaceTexture` is bound to) into the compositor's clip slot.
   * `slot=0` is the primary clip, `slot=1` is the transition partner.
   */
  fun setClipTexture(viewId: Int, slot: Int, oesTextureId: Int) {
    if (!ensure()) return
    runCatching { nativeSetClipTexture(viewId.toLong(), slot, oesTextureId) }
  }

  private external fun nativeAttachSurface(viewId: Long, surface: Surface, w: Int, h: Int)
  private external fun nativeResizeSurface(viewId: Long, w: Int, h: Int)
  private external fun nativeDetachSurface(viewId: Long)
  private external fun nativeSetClipTexture(viewId: Long, slot: Int, oesTexId: Int)
}
