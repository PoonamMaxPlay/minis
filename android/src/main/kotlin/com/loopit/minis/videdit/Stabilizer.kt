package com.loopit.minis.videdit

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Two-pass video stabilizer that wraps FFmpeg's `vidstabdetect` +
 * `vidstabtransform` filter pair.
 *
 * Pass 1 produces a transforms.trf file capturing per-frame motion vectors.
 * Pass 2 applies the transforms with a configurable smoothing window.
 *
 * The actual filter execution is performed by the native C bridge through
 * `ff_export_run` once we add a "stabilize" verb to the export pipeline.
 * Until then this class drives the work via the `processBuilder` fallback
 * (which only kicks in when the host ships an `ffmpeg` CLI binary — the
 * default app build does NOT, so behaviour here is best-effort).
 */
class Stabilizer(private val tmpDir: File) {

  enum class Mode(val shakiness: Int, val smoothing: Int, val zoom: Int) {
    LIGHT (shakiness =  3, smoothing =  6, zoom = 0),
    MEDIUM(shakiness =  5, smoothing = 10, zoom = 0),
    HEAVY (shakiness =  8, smoothing = 20, zoom = 5),
  }

  data class Progress(val pct: Double, val pass: Int, val etaSec: Double)

  fun stabilize(
      input: File,
      output: File,
      mode: Mode = Mode.MEDIUM,
      cancel: AtomicBoolean = AtomicBoolean(false),
      onProgress: ((Progress) -> Unit)? = null,
  ): Boolean {
    val trf = File(tmpDir, "transforms_${System.nanoTime()}.trf")
    try {
      // Pass 1 — detect.
      val detect = "vidstabdetect=shakiness=${mode.shakiness}:result=${trf.absolutePath}"
      if (!runFilter(input, null, detect, pass = 1, cancel, onProgress)) return false
      // Pass 2 — transform.
      val transform = "vidstabtransform=input=${trf.absolutePath}:zoom=${mode.zoom}:smoothing=${mode.smoothing}"
      if (!runFilter(input, output, transform, pass = 2, cancel, onProgress)) return false
      return true
    } finally {
      if (trf.exists()) trf.delete()
    }
  }

  private fun runFilter(
      input: File, output: File?, filter: String, pass: Int,
      cancel: AtomicBoolean, onProgress: ((Progress) -> Unit)?,
  ): Boolean {
    val args = mutableListOf("ffmpeg", "-y", "-i", input.absolutePath, "-vf", filter)
    if (output != null) args += output.absolutePath else args += listOf("-f", "null", "-")
    return try {
      val proc = ProcessBuilder(args).redirectErrorStream(true).start()
      proc.inputStream.bufferedReader().use { r ->
        r.lineSequence().forEach { line ->
          if (cancel.get()) { proc.destroyForcibly(); return false }
          val pctMatch = Regex("""time=([0-9:.]+)""").find(line)
          if (pctMatch != null) onProgress?.invoke(Progress(pct = 0.0, pass = pass, etaSec = 0.0))
        }
      }
      proc.waitFor() == 0
    } catch (_: Throwable) {
      // ffmpeg CLI not on PATH — Phase 2.5 will invoke the in-process FFmpeg
      // through a dedicated JNI verb instead of shelling out.
      false
    }
  }
}
