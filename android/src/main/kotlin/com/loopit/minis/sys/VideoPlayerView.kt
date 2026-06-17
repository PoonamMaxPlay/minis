package com.loopit.minis.sys

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class VideoPlayerViewFactory(
  private val messenger: BinaryMessenger,
  private val engine: VideoPlayerEngine
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    @Suppress("UNCHECKED_CAST")
    val params = args as? Map<String?, Any?>
    val playerId = params?.get("playerId") as? String ?: ""
    val hdrTonemap = params?.get("hdrTonemap") as? Boolean ?: true
    return VideoPlayerView(context, playerId, hdrTonemap, engine)
  }
}

class VideoPlayerView(
  context: Context,
  private val playerId: String,
  private val hdrTonemap: Boolean,
  private val engine: VideoPlayerEngine
) : PlatformView, SurfaceHolder.Callback {

  private val surfaceView = SurfaceView(context).apply {
    holder.addCallback(this@VideoPlayerView)
  }

  override fun getView(): View = surfaceView
  override fun dispose() {
    engine.detachSurface(playerId)
    surfaceView.holder.removeCallback(this)
  }

  override fun surfaceCreated(holder: SurfaceHolder) { engine.attachSurface(playerId, holder.surface) }
  override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
  override fun surfaceDestroyed(holder: SurfaceHolder) { engine.detachSurface(playerId) }

  companion object { const val VIEW_TYPE = "loopit/minis/player" }
}
