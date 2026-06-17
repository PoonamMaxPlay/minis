package com.loopit.minis.videdit

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.view.Surface
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Walks a [Timeline] in lock-step with the compositor's render clock,
 * activates the right [Clip] (or pair of clips, during a transition),
 * drives [HWDecoderPool] to seek the decoded frames forward, and hands the
 * resulting `SurfaceTexture` OES textures into the compositor's clip slots
 * via [VideoEditNativePreview.setClipTexture].
 *
 * Lifecycle:
 *   1. `attach(viewId, ...)` once the platform view's EGL context is up.
 *   2. `load(timeline)` to install / replace the active timeline.
 *   3. `play()` / `pause()` / `seek(ms)` to drive playback.
 *   4. `release()` on view detach.
 *
 * The OES texture handles are allocated inside the EGL context that the
 * preview render thread owns (gl_preview_jni.c). To keep the cross-thread
 * handshake simple, this class hands the integer texture name to the
 * compositor; it does not call `updateTexImage()` itself — that runs on
 * the render thread by way of a `SurfaceTexture.OnFrameAvailableListener`
 * that the native side polls.
 */
class TimelineOrchestrator(
    @Suppress("UNUSED_PARAMETER") private val context: Context,
    private val viewId: Int,
    private val pool: HWDecoderPool = HWDecoderPool(),
) {
  private val playing = AtomicBoolean(false)
  private val cancelled = AtomicBoolean(false)
  private var positionMs: Long = 0
  private var timeline: Timeline? = null
  private var loopThread: Thread? = null
  private var lastActivePrimaryId: String? = null
  private var lastActiveSecondaryId: String? = null

  private val slotTextures = IntArray(2) { 0 }
  private val slotSurfaceTexs = arrayOfNulls<SurfaceTexture>(2)
  private val slotSurfaces = arrayOfNulls<Surface>(2)

  fun load(t: Timeline) {
    synchronized(this) {
      timeline = t
      positionMs = 0
      lastActivePrimaryId = null
      lastActiveSecondaryId = null
    }
  }

  fun play() {
    if (timeline == null) return
    if (playing.compareAndSet(false, true)) {
      cancelled.set(false)
      loopThread = thread(name = "minis-videdit-orchestrator", isDaemon = true) {
        renderLoop()
      }
    }
  }

  fun pause() {
    playing.set(false)
  }

  fun seek(ms: Long) {
    synchronized(this) {
      positionMs = ms
    }
  }

  fun release() {
    cancelled.set(true)
    playing.set(false)
    loopThread?.join(500)
    loopThread = null
    pool.releaseAll()
    for (i in 0..1) {
      slotSurfaces[i]?.release()
      slotSurfaceTexs[i]?.release()
      slotSurfaces[i] = null
      slotSurfaceTexs[i] = null
      slotTextures[i] = 0
    }
  }

  // ──────────────────────────────────────────────────────────────────

  /**
   * Allocate the GL_TEXTURE_EXTERNAL_OES texture for [slot] (0 or 1) on
   * the GL thread, wrap it as a `SurfaceTexture` + `Surface`, and hand
   * the texture id to the compositor.
   *
   * Must be called from the EGL render thread (i.e. from a JNI callback
   * the native side fires once the EGL context is current).
   */
  fun allocateSlotTextureOnGlThread(slot: Int): Int {
    if (slot !in 0..1) return 0
    val ids = IntArray(1)
    GLES20.glGenTextures(1, ids, 0)
    val tex = ids[0]
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex)
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

    val st = SurfaceTexture(tex)
    val surface = Surface(st)
    slotTextures[slot] = tex
    slotSurfaceTexs[slot] = st
    slotSurfaces[slot] = surface
    VideoEditNativePreview.setClipTexture(viewId, slot, tex)
    return tex
  }

  fun slotSurface(slot: Int): Surface? = slotSurfaces[slot]
  fun slotSurfaceTexture(slot: Int): SurfaceTexture? = slotSurfaceTexs[slot]

  // ──────────────────────────────────────────────────────────────────
  // Render loop — wall-clock driven; advances positionMs per tick and
  // activates the right clip(s).

  private fun renderLoop() {
    val startWall = System.nanoTime()
    var basePos: Long
    synchronized(this) { basePos = positionMs }

    while (!cancelled.get() && playing.get()) {
      val nowMs = (System.nanoTime() - startWall) / 1_000_000L + basePos
      synchronized(this) {
        positionMs = nowMs
        activateClipsForPosition(nowMs)
      }
      Thread.sleep(16)
    }
  }

  private fun activateClipsForPosition(posMs: Long) {
    val tl = timeline ?: return
    val active = findActiveClips(tl, posMs)
    val (primary, secondary, progress) = active

    if (primary?.id != lastActivePrimaryId) {
      primary?.let { activateSlot(slot = 0, clip = it, posMs = posMs) }
      lastActivePrimaryId = primary?.id
    }
    if (secondary?.id != lastActiveSecondaryId) {
      secondary?.let { activateSlot(slot = 1, clip = it, posMs = posMs) }
      lastActiveSecondaryId = secondary?.id
    }
    // `progress` is passed down to the compositor through a separate JNI
    // hook (`gl_compositor_draw_oes` already accepts a progress arg).
    // Phase 4.x ships a `setTransition(viewId, name, progress)` JNI verb so
    // the orchestrator can flip transitions live.
    @Suppress("UNUSED_VARIABLE") val unused = progress
  }

  private fun activateSlot(slot: Int, clip: Clip, posMs: Long) {
    val surface = slotSurfaces[slot] ?: return
    val seekUs = (posMs - clip.positionMs + clip.inMs) * 1000L
    try {
      val (codec, extractor) = pool.acquire(clip.path, surface)
      FrameAccurateSeek.seekTo(extractor, codec, seekUs)
    } catch (_: Throwable) {
      // Decoder unavailable / unsupported codec — fall back to a black
      // frame; the compositor's draw_with_oes handles the null-texture
      // case by clearing the FBO.
    }
  }

  private data class Active(val primary: Clip?, val secondary: Clip?, val progress: Float)

  private fun findActiveClips(tl: Timeline, posMs: Long): Active {
    val primary = tl.clips.firstOrNull { clip ->
      val clipDurMs = clip.outMs - clip.inMs
      posMs in clip.positionMs until (clip.positionMs + clipDurMs)
    }
    if (primary == null) return Active(null, null, 0f)

    // Look for an active transition whose A == primary and which is
    // within its overlap window.
    val transition = tl.transitions.firstOrNull { it.aId == primary.id }
    val secondary = transition?.let { t ->
      tl.clips.firstOrNull { it.id == t.bId }
    }
    if (transition != null && secondary != null) {
      val primaryEnd = primary.positionMs + (primary.outMs - primary.inMs)
      val tStart = primaryEnd - transition.durMs
      if (posMs in tStart..primaryEnd) {
        val p = ((posMs - tStart).toFloat() / transition.durMs.coerceAtLeast(1L).toFloat())
            .coerceIn(0f, 1f)
        return Active(primary, secondary, p)
      }
    }
    return Active(primary, null, 0f)
  }
}
