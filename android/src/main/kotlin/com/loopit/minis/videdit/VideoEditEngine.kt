package com.loopit.minis.videdit

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * MethodChannel handler for `loopit/minis/videdit`. Backs every editing verb
 * with **AndroidX Media3 Transformer** instead of FFmpeg. Media3 wraps
 * `MediaCodec` + `MediaMuxer` so trim / concat / mute / transcode all run on
 * device hardware encoders without an external shared library.
 *
 * Why Media3 and not FFmpeg-from-source / FFmpegKit:
 *   * The from-source path in `android/ffmpeg/build_android.sh` produces .so
 *     files the bionic dynamic linker refuses (TLS IE relocs).
 *   * The FFmpegKit AAR (`com.arthenica:ffmpeg-kit-*`) was deprecated and the
 *     binaries were purged from Maven Central in January 2025.
 *
 * Channel surface unchanged so the Dart side (`MinisVidEdit`) keeps working.
 */
@OptIn(UnstableApi::class)
class VideoEditEngine(
    private val context: Context,
    messenger: BinaryMessenger,
) {
  private val method = MethodChannel(messenger, CHANNEL_METHOD).apply {
    setMethodCallHandler(::onMethodCall)
  }
  private val progress = EventChannel(messenger, CHANNEL_PROGRESS).apply {
    setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
      }
      override fun onCancel(arguments: Any?) { progressSink = null }
    })
  }
  private val state = EventChannel(messenger, CHANNEL_STATE).apply {
    setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        stateSink = events
      }
      override fun onCancel(arguments: Any?) { stateSink = null }
    })
  }

  private val executor = Executors.newFixedThreadPool(2)
  private val main = Handler(Looper.getMainLooper())
  private val activeTasks = ConcurrentHashMap<String, Transformer>()
  private var progressSink: EventChannel.EventSink? = null
  private var stateSink: EventChannel.EventSink? = null

  companion object {
    const val CHANNEL_METHOD = "loopit/minis/videdit"
    const val CHANNEL_PROGRESS = "loopit/minis/videdit/progress"
    const val CHANNEL_STATE = "loopit/minis/videdit/state"
  }

  fun dispose() {
    method.setMethodCallHandler(null)
    progress.setStreamHandler(null)
    state.setStreamHandler(null)
    for (t in activeTasks.values) {
      main.post { runCatching { t.cancel() } }
    }
    activeTasks.clear()
    executor.shutdownNow()
  }

  // ──────────────────────────────────────────────────────────────────
  // MethodChannel dispatch
  // ──────────────────────────────────────────────────────────────────

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "init" -> result.success(mapOf(
        "viewId" to "loopit/minis/videdit/preview",
        "ffmpegBuildInfo" to "media3-transformer/1.3.1",
        "engineAvailable" to true,
      ))
      "getCapabilities" -> result.success(buildCapabilities())
      "probe" -> handleProbe(call, result)
      "loadTimeline" -> handleLoadTimeline(call, result)
      "thumbnailStrip" -> handleThumbStrip(call, result)
      "thumbnailAt" -> handleThumbAt(call, result)
      "trim" -> handleTrim(call, result)
      "concat" -> handleConcat(call, result)
      "repair" -> handleRepair(call, result)
      "export" -> handleExport(call, result)
      "replaceAudio" -> handleReplaceAudio(call, result)
      "cancelTask" -> handleCancel(call, result)
      // Effects below need shader pipeline that Media3 Transformer doesn't
      // expose with a one-liner. Return notImplemented so the Dart side can
      // detect + skip cleanly rather than silently doing nothing.
      "burnCaptions", "composeBackground", "mixAudio",
      "addClip", "removeClip", "splitClip", "setClipTransform", "setClipSpeed",
      "setClipFilter", "addTransition", "addText", "addSticker",
      "addAudioTrack", "setMasterVolumeEnv", "stabilize", "denoise",
      "autoCaption", "seek", "play", "pause" ->
        result.error("unimplemented", "${call.method} not yet wired", null)
      else -> result.notImplemented()
    }
  }

  private fun buildCapabilities(): Map<String, Any?> = mapOf(
    "engineAvailable" to true,
    "ffmpegBuildInfo" to "media3-transformer/1.3.1",
    "hwEnc" to listOf("h264", "hevc"),
    "hwDec" to listOf("h264", "hevc", "vp9"),
    "codecs" to listOf("h264", "hevc", "vp9", "aac"),
    "maxResolution" to mapOf("width" to 3840, "height" to 2160),
  )

  // ──────────────────────────────────────────────────────────────────
  // Probe / timeline (MediaMetadataRetriever — no encoding involved).
  // ──────────────────────────────────────────────────────────────────

  private fun handleProbe(call: MethodCall, result: MethodChannel.Result) {
    val path = call.argument<String>("path") ?: return result.error("args", "path missing", null)
    executor.execute {
      val payload = runCatching { probeWithMmr(path) }.getOrDefault(emptyMap())
      main.post { result.success(payload) }
    }
  }

  private fun handleLoadTimeline(call: MethodCall, result: MethodChannel.Result) {
    val timeline = call.argument<Map<String, Any?>>("timeline") ?: emptyMap()
    @Suppress("UNCHECKED_CAST")
    val clips = (timeline["clips"] as? List<Map<String, Any?>>) ?: emptyList()
    val firstPath = clips.firstOrNull()?.get("path") as? String
    if (firstPath == null) return result.success(mapOf("durationMs" to 0L))
    executor.execute {
      val ms = runCatching { (probeWithMmr(firstPath)["durationMs"] as? Long) ?: 0L }
        .getOrDefault(0L)
      main.post { result.success(mapOf("durationMs" to ms)) }
    }
  }

  private fun probeWithMmr(path: String): Map<String, Any?> {
    val mmr = MediaMetadataRetriever()
    return try {
      mmr.setDataSource(path)
      val durMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
      val w = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toLongOrNull() ?: 0L
      val h = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toLongOrNull() ?: 0L
      val bitrate = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toLongOrNull() ?: 0L
      val vCodec = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE).orEmpty()
      mapOf(
        "durationMs" to durMs,
        "bitrate" to bitrate,
        "width" to w,
        "height" to h,
        "videoCodec" to vCodec,
        "audioCodec" to "",
        "sampleRate" to 0L,
        "channels" to "",
      )
    } finally {
      runCatching { mmr.release() }
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // Thumbnails delegate to the existing MediaMetadataRetriever helper.
  // ──────────────────────────────────────────────────────────────────

  private fun handleThumbStrip(call: MethodCall, result: MethodChannel.Result) {
    val path = call.argument<String>("path") ?: return result.error("args", "path", null)
    val count = call.argument<Int>("count") ?: 10
    val w = call.argument<Int>("w") ?: 160
    val h = call.argument<Int>("h") ?: 160
    val cacheDir = File(context.cacheDir, "vidthumb").apply { mkdirs() }
    executor.execute {
      try {
        val thumbs = Thumbnailer.strip(path, count, w, h, cacheDir)
        main.post { result.success(mapOf("thumbs" to thumbs)) }
      } catch (t: Throwable) {
        main.post { result.error("thumb_failed", t.message, null) }
      }
    }
  }

  private fun handleThumbAt(call: MethodCall, result: MethodChannel.Result) {
    val path = call.argument<String>("path") ?: return result.error("args", "path", null)
    val atMs = call.argument<Number>("atMs")?.toLong() ?: 0L
    val w = call.argument<Int>("w") ?: 240
    val h = call.argument<Int>("h") ?: 240
    executor.execute {
      val bytes = try { Thumbnailer.single(context, path, atMs, w, h) } catch (_: Throwable) { null }
      main.post { result.success(mapOf("bytes" to bytes?.toList())) }
    }
  }

  // ──────────────────────────────────────────────────────────────────
  // Trim / concat / repair / export — all dispatched via Media3 Transformer.
  // ──────────────────────────────────────────────────────────────────

  private fun handleTrim(call: MethodCall, result: MethodChannel.Result) {
    val inPath = call.argument<String>("inputPath") ?: return result.error("args", "inputPath", null)
    val outPath = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
    val endMs = call.argument<Number>("endMs")?.toLong() ?: 0L
    val taskId = UUID.randomUUID().toString()
    val mediaItem = MediaItem.Builder()
      .setUri(Uri.fromFile(File(inPath)))
      .setClippingConfiguration(
        MediaItem.ClippingConfiguration.Builder()
          .setStartPositionMs(startMs)
          .setEndPositionMs(endMs)
          .build()
      )
      .build()
    val edited = EditedMediaItem.Builder(mediaItem).build()
    startExport(taskId, listOf(edited), outPath, "trim_failed") { ok ->
      if (ok) result.success(mapOf("outputPath" to outPath, "taskId" to taskId))
      else result.error("trim_failed", "transformer reported failure", null)
    }
  }

  private fun handleConcat(call: MethodCall, result: MethodChannel.Result) {
    val paths = call.argument<List<String>>("inputPaths") ?: return result.error("args", "inputPaths", null)
    val outPath = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val keepAudio = call.argument<Boolean>("keepAudio") ?: true
    val taskId = call.argument<String>("taskId")?.ifBlank { null } ?: UUID.randomUUID().toString()
    if (paths.isEmpty()) return result.error("args", "inputPaths empty", null)

    val items = paths.map { p ->
      EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(p))))
        .setRemoveAudio(!keepAudio)
        .build()
    }
    startExport(taskId, items, outPath, "concat_failed") { ok ->
      if (ok) result.success(mapOf("outputPath" to outPath, "taskId" to taskId))
      else result.error("concat_failed", "transformer reported failure", null)
    }
  }

  private fun handleRepair(call: MethodCall, result: MethodChannel.Result) {
    val inPath = call.argument<String>("inputPath") ?: return result.error("args", "inputPath", null)
    val outPath = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val taskId = UUID.randomUUID().toString()
    val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(inPath)))).build()
    startExport(taskId, listOf(item), outPath, "repair_failed") { ok ->
      if (ok) result.success(mapOf("outputPath" to outPath))
      else result.success(mapOf("outputPath" to null))
    }
  }

  private fun handleExport(call: MethodCall, result: MethodChannel.Result) {
    val out = call.argument<String>("outPath") ?: return result.error("args", "outPath", null)
    val options = call.argument<Map<String, Any?>>("options") ?: emptyMap()
    val src = options["inputPath"] as? String ?: return result.error("args", "options.inputPath", null)
    val taskId = UUID.randomUUID().toString()
    val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(src)))).build()
    startExport(taskId, listOf(item), out, "export_failed") { ok ->
      if (ok) result.success(mapOf("taskId" to taskId, "outputPath" to out))
      else result.error("export_failed", "transformer reported failure", null)
    }
  }

  private fun handleReplaceAudio(call: MethodCall, result: MethodChannel.Result) {
    val v = call.argument<String>("videoPath") ?: return result.error("args", "videoPath", null)
    val a = call.argument<String>("audioPath") ?: return result.error("args", "audioPath", null)
    val out = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val taskId = UUID.randomUUID().toString()
    // 1) Strip audio off the video. 2) Source audio-only track. 3) Sequence them
    //    in parallel via Composition — Transformer 1.3 supports a video track
    //    plus an audio track in the same Composition.
    val videoItem = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(v))))
      .setRemoveAudio(true)
      .build()
    val audioItem = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(a))))
      .setRemoveVideo(true)
      .build()
    val composition = Composition.Builder(
      EditedMediaItemSequence(videoItem),
      EditedMediaItemSequence(audioItem),
    ).build()
    val transformer = newTransformer(taskId, "remux_failed") { ok ->
      if (ok) result.success(mapOf("outputPath" to out, "taskId" to taskId))
      else result.error("remux_failed", "transformer reported failure", null)
    }
    activeTasks[taskId] = transformer
    main.post { runCatching { transformer.start(composition, out) }.onFailure { activeTasks.remove(taskId) } }
  }

  private fun handleCancel(call: MethodCall, result: MethodChannel.Result) {
    val taskId = call.argument<String>("taskId") ?: return result.error("args", "taskId", null)
    val t = activeTasks.remove(taskId)
    if (t != null) main.post { runCatching { t.cancel() } }
    result.success(null)
  }

  // ──────────────────────────────────────────────────────────────────
  // Transformer plumbing.
  // ──────────────────────────────────────────────────────────────────

  private fun startExport(
      taskId: String,
      items: List<EditedMediaItem>,
      outPath: String,
      errCode: String,
      done: (Boolean) -> Unit,
  ) {
    val sequence = EditedMediaItemSequence(items)
    val composition = Composition.Builder(sequence).build()
    val transformer = newTransformer(taskId, errCode, done)
    activeTasks[taskId] = transformer
    // Transformer requires construction + start on the application main thread.
    main.post {
      runCatching { transformer.start(composition, outPath) }
        .onFailure {
          activeTasks.remove(taskId)
          done(false)
        }
    }
  }

  private fun newTransformer(taskId: String, errCode: String, done: (Boolean) -> Unit): Transformer {
    return Transformer.Builder(context)
      .setVideoMimeType(MimeTypes.VIDEO_H264)
      .setAudioMimeType(MimeTypes.AUDIO_AAC)
      .addListener(object : Transformer.Listener {
        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
          activeTasks.remove(taskId)
          done(true)
        }

        override fun onError(
          composition: Composition,
          exportResult: ExportResult,
          exportException: ExportException,
        ) {
          activeTasks.remove(taskId)
          done(false)
        }
      })
      .build()
  }
}
