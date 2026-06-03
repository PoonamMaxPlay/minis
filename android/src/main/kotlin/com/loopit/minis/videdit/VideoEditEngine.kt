package com.loopit.minis.videdit

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * MethodChannel handler for `loopit/minis/videdit`. Owns the FFmpeg-backed
 * session probe and routes per-method calls onto a background executor.
 *
 * The JNI side is implemented in `android/src/main/cpp/videdit/ff_jni.c`
 * and shipped through `libminis_videdit.so`.
 */
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
  private val activeTasks = ConcurrentHashMap<String, Boolean>()
  private var progressSink: EventChannel.EventSink? = null
  private var stateSink: EventChannel.EventSink? = null

  companion object {
    const val CHANNEL_METHOD = "loopit/minis/videdit"
    const val CHANNEL_PROGRESS = "loopit/minis/videdit/progress"
    const val CHANNEL_STATE = "loopit/minis/videdit/state"

    @Volatile private var nativeLoaded = false
    private fun ensureNative(): Boolean {
      if (nativeLoaded) return true
      return try {
        System.loadLibrary("avutil")
        System.loadLibrary("swresample")
        System.loadLibrary("swscale")
        System.loadLibrary("avcodec")
        System.loadLibrary("avformat")
        System.loadLibrary("avfilter")
        System.loadLibrary("minis_videdit")
        nativeLoaded = true
        true
      } catch (t: Throwable) {
        nativeLoaded = false
        false
      }
    }
  }

  init {
    ensureNative()
  }

  fun dispose() {
    method.setMethodCallHandler(null)
    progress.setStreamHandler(null)
    state.setStreamHandler(null)
    executor.shutdownNow()
  }

  // ──────────────────────────────────────────────────────────────────
  // MethodChannel dispatch
  // ──────────────────────────────────────────────────────────────────

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "init" -> result.success(mapOf(
        "viewId" to "loopit/minis/videdit/preview",
        "ffmpegBuildInfo" to nativeBuildInfo(),
        "engineAvailable" to ensureNative(),
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
      "burnCaptions" -> handleBurnCaptions(call, result)
      "composeBackground" -> handleComposeBackground(call, result)
      "mixAudio" -> handleMixAudio(call, result)
      "replaceAudio" -> handleReplaceAudio(call, result)
      "cancelTask" -> handleCancel(call, result)
      "addClip", "removeClip", "splitClip", "setClipTransform", "setClipSpeed",
      "setClipFilter", "addTransition", "addText", "addSticker",
      "addAudioTrack", "setMasterVolumeEnv", "stabilize", "denoise",
      "autoCaption", "seek", "play", "pause" ->
        result.error("unimplemented", "${call.method} not yet wired", null)
      else -> result.notImplemented()
    }
  }

  private fun buildCapabilities(): Map<String, Any?> {
    if (!ensureNative()) {
      return mapOf(
        "engineAvailable" to false,
        "ffmpegBuildInfo" to "",
        "hwEnc" to emptyList<String>(),
        "hwDec" to emptyList<String>(),
        "codecs" to emptyList<String>(),
        "maxResolution" to mapOf("width" to 0, "height" to 0),
      )
    }
    val raw = nativeCapabilities() ?: emptyMap<String, Any>()
    return mapOf(
      "engineAvailable" to true,
      "ffmpegBuildInfo" to (raw["ffmpegBuildInfo"] ?: ""),
      "hwEnc" to buildList<String> {
        if (raw["hwEncH264"] == true) add("h264")
        if (raw["hwEncHevc"] == true) add("hevc")
      },
      "hwDec" to buildList<String> {
        if (raw["hwDecH264"] == true) add("h264")
        if (raw["hwDecHevc"] == true) add("hevc")
        if (raw["hwDecVp9"]  == true) add("vp9")
      },
      "codecs" to listOf("h264", "hevc", "vp9", "aac", "opus"),
      "maxResolution" to mapOf(
        "width" to (raw["maxWidth"] ?: 3840),
        "height" to (raw["maxHeight"] ?: 2160),
      ),
    )
  }

  private fun handleProbe(call: MethodCall, result: MethodChannel.Result) {
    val path = call.argument<String>("path") ?: return result.error(
      "args", "path missing", null)
    if (!ensureNative()) {
      return result.error("unimplemented", "native engine not built", null)
    }
    executor.execute {
      val handle = nativeOpen(path)
      if (handle == 0L) {
        main.post { result.error("probe_failed", "open failed for $path", null) }
        return@execute
      }
      val info = nativeInfo(handle)
      nativeClose(handle)
      main.post { result.success(info ?: emptyMap<String, Any?>()) }
    }
  }

  private fun handleLoadTimeline(call: MethodCall, result: MethodChannel.Result) {
    val timeline = call.argument<Map<String, Any?>>("timeline") ?: emptyMap()
    val clips = (timeline["clips"] as? List<Map<String, Any?>>) ?: emptyList()
    val firstPath = clips.firstOrNull()?.get("path") as? String
    if (firstPath == null) return result.success(mapOf("durationMs" to 0L))
    if (!ensureNative()) {
      return result.success(mapOf("durationMs" to 0L))
    }
    executor.execute {
      val handle = nativeOpen(firstPath)
      val ms = if (handle != 0L) {
        val info = nativeInfo(handle)
        nativeClose(handle)
        (info?.get("durationMs") as? Number)?.toLong() ?: 0L
      } else 0L
      main.post { result.success(mapOf("durationMs" to ms)) }
    }
  }

  private fun handleThumbStrip(call: MethodCall, result: MethodChannel.Result) {
    val path = call.argument<String>("path") ?: return result.error("args", "path", null)
    val count = call.argument<Int>("count") ?: 10
    val w = call.argument<Int>("w") ?: 160
    val h = call.argument<Int>("h") ?: 160
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
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
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    executor.execute {
      val bytes = try { Thumbnailer.single(context, path, atMs, w, h) } catch (_: Throwable) { null }
      main.post { result.success(mapOf("bytes" to bytes?.toList())) }
    }
  }

  private fun handleTrim(call: MethodCall, result: MethodChannel.Result) {
    val inPath = call.argument<String>("inputPath") ?: return result.error("args", "inputPath", null)
    val outPath = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
    val endMs = call.argument<Number>("endMs")?.toLong() ?: 0L
    val reencode = call.argument<Boolean>("reencode") ?: true
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    val taskId = UUID.randomUUID().toString()
    activeTasks[taskId] = true
    executor.execute {
      val rc = nativeTrim(inPath, outPath, startMs, endMs, reencode, makeProgressSink(taskId))
      activeTasks.remove(taskId)
      main.post {
        if (rc == 0) result.success(mapOf("outputPath" to outPath, "taskId" to taskId))
        else result.error("trim_failed", "rc=$rc", null)
      }
    }
  }

  private fun handleConcat(call: MethodCall, result: MethodChannel.Result) {
    val paths = call.argument<List<String>>("inputPaths") ?: return result.error("args", "inputPaths", null)
    val out = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val speed = call.argument<Double>("speed") ?: 1.0
    val keepAudio = call.argument<Boolean>("keepAudio") ?: true
    val music = call.argument<String>("musicPath")
    val musicIn = call.argument<Number>("musicStartMs")?.toLong() ?: 0L
    val musicOut = call.argument<Number>("musicEndMs")?.toLong() ?: 0L
    val keepTempo = call.argument<Boolean>("keepMusicTempo") ?: false
    val taskId = call.argument<String>("taskId")?.ifBlank { null } ?: UUID.randomUUID().toString()
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    activeTasks[taskId] = true
    executor.execute {
      val rc = nativeConcat(paths.toTypedArray(), out, speed, keepAudio,
                            music, musicIn, musicOut, keepTempo, makeProgressSink(taskId))
      activeTasks.remove(taskId)
      main.post {
        if (rc == 0) result.success(mapOf("outputPath" to out, "taskId" to taskId))
        else result.error("concat_failed", "rc=$rc", null)
      }
    }
  }

  private fun handleRepair(call: MethodCall, result: MethodChannel.Result) {
    val inPath = call.argument<String>("inputPath") ?: return result.error("args", "inputPath", null)
    val outPath = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val targetH = call.argument<Int>("targetHeight") ?: 720
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    val taskId = UUID.randomUUID().toString()
    activeTasks[taskId] = true
    executor.execute {
      val rc = nativeRepair(inPath, outPath, targetH, makeProgressSink(taskId))
      activeTasks.remove(taskId)
      main.post {
        if (rc == 0) result.success(mapOf("outputPath" to outPath))
        else result.success(mapOf("outputPath" to null))
      }
    }
  }

  private fun handleExport(call: MethodCall, result: MethodChannel.Result) {
    val preset = call.argument<String>("preset") ?: "feed"
    val out = call.argument<String>("outPath") ?: return result.error("args", "outPath", null)
    val options = call.argument<Map<String, Any?>>("options") ?: emptyMap()
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    val taskId = UUID.randomUUID().toString()
    activeTasks[taskId] = true
    val timelineJson = "{}"      // Phase 2.5: populated by Timeline.kt once it lands.
    val optionsJson = jsonOf(options)
    executor.execute {
      val rc = nativeExport(timelineJson, preset, out, optionsJson, makeProgressSink(taskId))
      activeTasks.remove(taskId)
      main.post {
        if (rc == 0) result.success(mapOf("taskId" to taskId, "outputPath" to out))
        else result.error("export_failed", "rc=$rc", null)
      }
    }
  }

  private fun handleBurnCaptions(call: MethodCall, result: MethodChannel.Result) {
    val inPath = call.argument<String>("inputPath") ?: return result.error("args", "inputPath", null)
    val outPath = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val srt = call.argument<String>("srtPath") ?: return result.error("args", "srtPath", null)
    val style = call.argument<String>("style").orEmpty()
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    val taskId = UUID.randomUUID().toString()
    activeTasks[taskId] = true
    executor.execute {
      val rc = nativeBurnCaptions(inPath, outPath, srt, style, makeProgressSink(taskId))
      activeTasks.remove(taskId)
      main.post {
        if (rc == 0) result.success(mapOf("outputPath" to outPath, "taskId" to taskId))
        else result.error("captions_failed", "rc=$rc", null)
      }
    }
  }

  private fun handleComposeBackground(call: MethodCall, result: MethodChannel.Result) {
    val inPath = call.argument<String>("inputPath") ?: return result.error("args", "inputPath", null)
    val maskAtlas = call.argument<String>("maskAtlasPath") ?: return result.error("args", "maskAtlasPath", null)
    val outPath = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    val bgSpec = call.argument<String>("bgSpec") ?: "#000000"
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    val taskId = UUID.randomUUID().toString()
    activeTasks[taskId] = true
    executor.execute {
      val rc = nativeComposeBackground(inPath, maskAtlas, bgSpec, outPath, makeProgressSink(taskId))
      activeTasks.remove(taskId)
      main.post {
        if (rc == 0) result.success(mapOf("outputPath" to outPath, "taskId" to taskId))
        else result.error("bgcompose_failed", "rc=$rc", null)
      }
    }
  }

  private fun handleMixAudio(call: MethodCall, result: MethodChannel.Result) {
    val inputs = call.argument<List<String>>("audioInputs") ?: return result.error("args", "audioInputs", null)
    val filter = call.argument<String>("filter") ?: return result.error("args", "filter", null)
    val out = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    val taskId = UUID.randomUUID().toString()
    activeTasks[taskId] = true
    executor.execute {
      val rc = nativeMixAudio(inputs.toTypedArray(), filter, out, makeProgressSink(taskId))
      activeTasks.remove(taskId)
      main.post {
        if (rc == 0) result.success(mapOf("outputPath" to out, "taskId" to taskId))
        else result.error("mix_failed", "rc=$rc", null)
      }
    }
  }

  private fun handleReplaceAudio(call: MethodCall, result: MethodChannel.Result) {
    val v = call.argument<String>("videoPath") ?: return result.error("args", "videoPath", null)
    val a = call.argument<String>("audioPath") ?: return result.error("args", "audioPath", null)
    val out = call.argument<String>("outputPath") ?: return result.error("args", "outputPath", null)
    if (!ensureNative()) return result.error("unimplemented", "engine missing", null)
    val taskId = UUID.randomUUID().toString()
    activeTasks[taskId] = true
    executor.execute {
      val rc = nativeReplaceAudio(v, a, out, makeProgressSink(taskId))
      activeTasks.remove(taskId)
      main.post {
        if (rc == 0) result.success(mapOf("outputPath" to out, "taskId" to taskId))
        else result.error("remux_failed", "rc=$rc", null)
      }
    }
  }

  private fun handleCancel(call: MethodCall, result: MethodChannel.Result) {
    val taskId = call.argument<String>("taskId") ?: return result.error("args", "taskId", null)
    activeTasks.remove(taskId)
    nativeCancel(taskId)
    result.success(null)
  }

  // ──────────────────────────────────────────────────────────────────
  // Progress sink — kotlin Function2<String, Map, Unit> handed to JNI.
  // ──────────────────────────────────────────────────────────────────

  private fun makeProgressSink(taskId: String): ((String, Map<String, Any?>) -> Unit)? {
    val sink = progressSink ?: return null
    return { _, payload ->
      main.post {
        val merged = HashMap<String, Any?>(payload).apply { put("taskId", taskId) }
        sink.success(merged)
      }
    }
  }

  private fun jsonOf(map: Map<String, Any?>): String {
    val sb = StringBuilder("{")
    var first = true
    for ((k, v) in map) {
      if (!first) sb.append(',')
      first = false
      sb.append('"').append(k.replace("\"", "\\\"")).append('"').append(':')
      when (v) {
        null -> sb.append("null")
        is Number, is Boolean -> sb.append(v.toString())
        is Map<*, *> -> {
          @Suppress("UNCHECKED_CAST")
          sb.append(jsonOf(v as Map<String, Any?>))
        }
        else -> sb.append('"').append(v.toString().replace("\"", "\\\"")).append('"')
      }
    }
    sb.append('}')
    return sb.toString()
  }

  private fun nativeBuildInfo(): String =
    if (ensureNative()) (nativeCapabilities()?.get("ffmpegBuildInfo") as? String).orEmpty() else ""

  // JNI surface — implemented in ff_jni.c.
  private external fun nativeOpen(path: String): Long
  private external fun nativeInfo(handle: Long): Map<String, Any?>?
  private external fun nativeClose(handle: Long)
  private external fun nativeCapabilities(): Map<String, Any?>?
  private external fun nativeTrim(
    input: String, output: String, inMs: Long, outMs: Long, reencode: Boolean,
    sink: ((String, Map<String, Any?>) -> Unit)?,
  ): Int
  private external fun nativeConcat(
    paths: Array<String>, output: String, speed: Double, keepAudio: Boolean,
    music: String?, musicIn: Long, musicOut: Long, keepMusicTempo: Boolean,
    sink: ((String, Map<String, Any?>) -> Unit)?,
  ): Int
  private external fun nativeRepair(
    input: String, output: String, targetHeight: Int,
    sink: ((String, Map<String, Any?>) -> Unit)?,
  ): Int
  private external fun nativeThumbStrip(
    input: String, count: Int, w: Int, h: Int, cacheDir: String,
  ): Array<String>?
  private external fun nativeExport(
    timelineJson: String, preset: String, outPath: String, optionsJson: String,
    sink: ((String, Map<String, Any?>) -> Unit)?,
  ): Int
  private external fun nativeCancel(taskId: String): Int
  private external fun nativeBurnCaptions(
    input: String, output: String, srt: String, style: String,
    sink: ((String, Map<String, Any?>) -> Unit)?,
  ): Int
  private external fun nativeComposeBackground(
    input: String, maskAtlas: String, bgSpec: String, output: String,
    sink: ((String, Map<String, Any?>) -> Unit)?,
  ): Int
  private external fun nativeMixAudio(
    inputs: Array<String>, filter: String, output: String,
    sink: ((String, Map<String, Any?>) -> Unit)?,
  ): Int
  private external fun nativeReplaceAudio(
    videoPath: String, audioPath: String, output: String,
    sink: ((String, Map<String, Any?>) -> Unit)?,
  ): Int
}
