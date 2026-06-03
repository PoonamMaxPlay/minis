package com.loopit.minis

import androidx.annotation.NonNull
import com.loopit.minis.audio.MinisAudioPlugin
import com.loopit.minis.camera.CameraPlatformViewFactory
import com.loopit.minis.camera.CameraSession
import com.loopit.minis.camera.CameraXEngine
import com.loopit.minis.camera.FrameWatchdog
import com.loopit.minis.camera.MinisPermissions
import com.loopit.minis.imgedit.AssetCatalog
import com.loopit.minis.imgedit.EmojiPickerViewFactory
import com.loopit.minis.imgedit.ImageEditPlatformViewFactory
import com.loopit.minis.imgedit.ImageEditPluginRouter
import com.loopit.minis.videdit.VideoEditEngine
import com.loopit.minis.videdit.VideoEditPlatformViewFactory
import com.loopit.minis.sys.DeviceInfo
import com.loopit.minis.sys.FilePickerNative
import com.loopit.minis.sys.MediaPicker
import com.loopit.minis.sys.Paths
import com.loopit.minis.sys.Permissions
import com.loopit.minis.sys.Share
import com.loopit.minis.sys.VideoPlayerEngine
import com.loopit.minis.sys.VideoPlayerView
import com.loopit.minis.sys.VideoPlayerViewFactory
import com.loopit.minis.sys.Wakelock
import com.loopit.minis.telemetry.Telemetry
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class LoopitMinisPlugin: FlutterPlugin, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
  private var methodChannel: MethodChannel? = null
  private var minisPermsChannel: MethodChannel? = null
  private var stateChannel: EventChannel? = null
  private var audioChannel: EventChannel? = null
  private var metaChannel: EventChannel? = null
  private var analysisChannel: EventChannel? = null
  private var framesChannel: EventChannel? = null
  private var stateSink: EventChannel.EventSink? = null
  private var audioSink: EventChannel.EventSink? = null
  private var metaSink: EventChannel.EventSink? = null
  private var analysisSink: EventChannel.EventSink? = null
  private var framesSink: EventChannel.EventSink? = null
  private val minisCameraPerms = MinisPermissions()

  private var paths: Paths? = null
  private var wakelock: Wakelock? = null
  private var permissions: Permissions? = null
  private var deviceInfo: DeviceInfo? = null
  private var filePicker: FilePickerNative? = null
  private var mediaPicker: MediaPicker? = null
  private var share: Share? = null
  private var playerEngine: VideoPlayerEngine? = null
  private var audioPlugin: MinisAudioPlugin? = null
  private var videoEditEngine: VideoEditEngine? = null
  private var telemetry: Telemetry? = null
  private var imgEditMemoryCallback: android.content.ComponentCallbacks2? = null

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    val ctx = flutterPluginBinding.applicationContext
    val messenger = flutterPluginBinding.binaryMessenger

    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "minis_preview_player",
        MinisPreviewPlayerFactory(messenger)
    )
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "minis_native_camera",
        MinisNativeCameraPlatformViewFactory()
    )
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "loopit/minis/camera/preview",
        CameraPlatformViewFactory(MinisCameraXBridge.engine, secondary = false)
    )
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "loopit/minis/camera/preview_secondary",
        CameraPlatformViewFactory(MinisCameraXBridge.engine, secondary = true)
    )
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "loopit/minis/imgedit/canvas",
        ImageEditPlatformViewFactory(messenger)
    )
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "loopit/minis/emoji_picker",
        EmojiPickerViewFactory(messenger)
    )
    AssetCatalog.bind(ctx)
    ImageEditPluginRouter.attach(messenger)
    val app = ctx.applicationContext
    if (app is android.app.Application) {
      imgEditMemoryCallback = object : android.content.ComponentCallbacks2 {
        override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {}
        override fun onLowMemory() {
          ImageEditPluginRouter.notifyMemoryPressure(null, 0)
        }
        override fun onTrimMemory(level: Int) {
          ImageEditPluginRouter.notifyMemoryPressure(null, level)
        }
      }
      app.registerComponentCallbacks(imgEditMemoryCallback)
    }
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "loopit/minis/videdit/preview",
        VideoEditPlatformViewFactory(messenger)
    )
    videoEditEngine = VideoEditEngine(ctx, messenger)
    telemetry = Telemetry(messenger)

    paths = Paths(ctx, messenger)
    wakelock = Wakelock(messenger)
    permissions = Permissions(ctx, messenger)
    deviceInfo = DeviceInfo(ctx, messenger)
    filePicker = FilePickerNative(ctx)
    mediaPicker = MediaPicker(ctx, messenger, filePicker!!)
    share = Share(ctx, messenger)
    audioPlugin = MinisAudioPlugin.attach(flutterPluginBinding)
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "loopit/minis/audio/waveform",
        com.loopit.minis.audio.WaveformViewFactory(messenger)
    )
    playerEngine = VideoPlayerEngine(ctx, messenger).also { engine ->
      flutterPluginBinding.platformViewRegistry.registerViewFactory(
        VideoPlayerView.VIEW_TYPE,
        VideoPlayerViewFactory(messenger, engine)
      )
    }

    methodChannel = MethodChannel(messenger, "com.buzzit.social/minis_native_camera")
    methodChannel?.setMethodCallHandler(::onCameraMethodCall)

    minisPermsChannel = MethodChannel(messenger, "loopit/minis/permissions").also { ch ->
      ch.setMethodCallHandler { call, result ->
        when (call.method) {
          "status" -> minisCameraPerms.status(result)
          "requestCamera" -> minisCameraPerms.requestCamera(result)
          "requestMicrophone" -> minisCameraPerms.requestMic(result)
          "openSettings" -> {
            val a = ctx.applicationContext
            val intent = android.content.Intent(
              android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
              android.net.Uri.fromParts("package", a.packageName, null),
            ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            a.startActivity(intent)
            result.success(null)
          }
          else -> result.notImplemented()
        }
      }
    }

    val chanPrefix = "com.buzzit.social/minis_native_camera"
    stateChannel = EventChannel(messenger, "$chanPrefix/state").also { c ->
      c.setStreamHandler(object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { stateSink = events }
        override fun onCancel(arguments: Any?) { stateSink = null }
      })
    }
    audioChannel = EventChannel(messenger, "$chanPrefix/audio_levels").also { c ->
      c.setStreamHandler(object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { audioSink = events }
        override fun onCancel(arguments: Any?) { audioSink = null }
      })
    }
    metaChannel = EventChannel(messenger, "$chanPrefix/metadata").also { c ->
      c.setStreamHandler(object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { metaSink = events }
        override fun onCancel(arguments: Any?) { metaSink = null }
      })
    }
    analysisChannel = EventChannel(messenger, "$chanPrefix/analysis").also { c ->
      c.setStreamHandler(object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { analysisSink = events }
        override fun onCancel(arguments: Any?) { analysisSink = null }
      })
    }
    framesChannel = EventChannel(messenger, "$chanPrefix/frames").also { c ->
      c.setStreamHandler(object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { framesSink = events }
        override fun onCancel(arguments: Any?) { framesSink = null }
      })
    }

    MinisCameraXBridge.engine.setSession(
      CameraSession.Listener { _, next, code, message ->
        stateSink?.success(
          mapOf(
            "state" to next.name.lowercase(),
            "code" to code,
            "message" to message,
          )
        )
      }
    )
    MinisCameraXBridge.engine.attachFrameWatchdog(
      FrameWatchdog.Listener { gap ->
        stateSink?.success(
          mapOf("state" to "error", "code" to "NO_FRAME", "message" to "no frame for ${gap}ms")
        )
      }
    )
    MinisCameraXBridge.engine.setMetadataListener(
      CameraXEngine.MetadataListener { iso, shutterNs, evIndex, focus, wbKelvin, lensRatio ->
        metaSink?.success(
          mapOf(
            "iso" to iso,
            "shutterNs" to shutterNs,
            "ev" to evIndex,
            "focus" to focus,
            "wbKelvin" to wbKelvin,
            "lensRatio" to lensRatio,
            "frameTs" to System.currentTimeMillis(),
          )
        )
      }
    )
    MinisCameraXBridge.engine.setAnalysisListener(
      CameraXEngine.AnalysisListener { faces -> analysisSink?.success(mapOf("faces" to faces)) }
    )
    MinisCameraXBridge.engine.setAudioLevelListener(
      CameraXEngine.AudioLevelListener { peak, rms ->
        audioSink?.success(mapOf("peak" to peak, "rms" to rms))
      }
    )
    MinisCameraXBridge.engine.setFrameListener(
      CameraXEngine.FrameListener { w, h, bytes ->
        framesSink?.success(mapOf("width" to w, "height" to h, "bytes" to bytes))
      }
    )
  }

  @Suppress("LongMethod", "CyclomaticComplexMethod")
  private fun onCameraMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      // Legacy / minimal API.
      "warmUp", "init" -> {
        val args = call.arguments as? Map<*, *>
        val frames = args?.get("frames") as? Boolean ?: false
        MinisCameraXBridge.engine.enableFrameStream(frames)
        MinisCameraXBridge.warmUp(result)
      }
      "bind" -> {
        val args = call.arguments as? Map<*, *>
        val tier = (args?.get("qualityTier") as? Number)?.toInt() ?: 2
        val enableAudio = (args?.get("enableAudio") as? Boolean) ?: true
        MinisCameraXBridge.bind(tier, enableAudio, result)
      }
      "startRecording" -> {
        val path = call.arguments as? String
        MinisCameraXBridge.startRecording(path, result)
      }
      "stopRecording" -> MinisCameraXBridge.stopRecording(result)
      "takePicture" -> MinisCameraXBridge.takePicture(result)
      "switchCamera" -> MinisCameraXBridge.switchCamera(result)
      "setTorchEnabled" -> {
        val on = call.arguments as? Boolean ?: false
        MinisCameraXBridge.setTorchEnabled(on, result)
      }
      "getMinZoom" -> MinisCameraXBridge.getMinZoom(result)
      "getMaxZoom" -> MinisCameraXBridge.getMaxZoom(result)
      "setZoomLevel" -> {
        val ratio = call.arguments as? Double
          ?: (call.arguments as? Number)?.toDouble()
          ?: 1.0
        MinisCameraXBridge.setZoomLevel(ratio, result)
      }
      "setRecordWithAudio" -> {
        val on = call.arguments as? Boolean ?: true
        MinisCameraXBridge.setRecordWithAudio(on, result)
      }
      "dispose" -> {
        MinisCameraXBridge.disposeForFlutter()
        result.success(null)
      }

      // Extended spec API.
      "setLens" -> {
        val args = call.arguments as? Map<*, *>
        val facing = (args?.get("lensFacing") as? String) ?: "back"
        MinisCameraXBridge.engine.setLens(facing) { err ->
          if (err == null) result.success(null) else result.error("LENS_FAILED", err.message, null)
        }
      }
      "setFlash" -> {
        val args = call.arguments as? Map<*, *>
        val mode = (args?.get("mode") as? String) ?: "off"
        MinisCameraXBridge.engine.setFlash(mode) { err ->
          if (err == null) result.success(null) else result.error("FLASH_FAILED", err.message, null)
        }
      }
      "setZoom" -> {
        val args = call.arguments as? Map<*, *>
        val ratio = (args?.get("ratio") as? Number)?.toDouble() ?: 1.0
        MinisCameraXBridge.engine.setZoomRatio(ratio) { err ->
          if (err == null) result.success(null) else result.error("ZOOM_FAILED", err.message, null)
        }
      }
      "setExposure" -> {
        val args = call.arguments as? Map<*, *>
        val ev = (args?.get("ev") as? Number)?.toDouble() ?: 0.0
        MinisCameraXBridge.engine.setExposureBias(ev) { err ->
          if (err == null) result.success(null) else result.error("EV_FAILED", err.message, null)
        }
      }
      "setManual" -> {
        val args = call.arguments as? Map<*, *>
        val iso = (args?.get("iso") as? Number)?.toInt()
        val shutter = (args?.get("shutterNs") as? Number)?.toLong()
        val wb = (args?.get("wbKelvin") as? Number)?.toInt()
        val lens = (args?.get("lensPos") as? Number)?.toDouble()
        MinisCameraXBridge.engine.setManual(iso, shutter, wb, lens) { err ->
          if (err == null) result.success(null) else result.error("MANUAL_FAILED", err.message, null)
        }
      }
      "tapToFocus" -> {
        val args = call.arguments as? Map<*, *>
        val x = (args?.get("x") as? Number)?.toDouble() ?: 0.5
        val y = (args?.get("y") as? Number)?.toDouble() ?: 0.5
        MinisCameraXBridge.engine.tapToFocus(x, y) { err ->
          if (err == null) result.success(null) else result.error("FOCUS_FAILED", err.message, null)
        }
      }
      "setResolution" -> {
        val args = call.arguments as? Map<*, *>
        val w = (args?.get("w") as? Number)?.toInt() ?: 1280
        val h = (args?.get("h") as? Number)?.toInt() ?: 720
        val fps = (args?.get("fps") as? Number)?.toInt() ?: 30
        MinisCameraXBridge.engine.setResolution(w, h, fps) { ok, err ->
          if (err == null) result.success(mapOf("accepted" to ok))
          else result.error("RES_FAILED", err.message, null)
        }
      }
      "enableHdr" -> {
        val args = call.arguments as? Map<*, *>
        val on = args?.get("on") as? Boolean ?: false
        MinisCameraXBridge.engine.enableHdr(on) { enabled ->
          result.success(mapOf("enabled" to enabled))
        }
      }
      "enableSlowMo" -> {
        val args = call.arguments as? Map<*, *>
        val fps = (args?.get("fps") as? Number)?.toInt() ?: 120
        MinisCameraXBridge.engine.enableSlowMo(fps) { enabled, actual ->
          result.success(mapOf("enabled" to enabled, "actualFps" to actual))
        }
      }
      "enableTimeLapse" -> {
        val args = call.arguments as? Map<*, *>
        val interval = (args?.get("intervalMs") as? Number)?.toLong() ?: 1000
        val duration = (args?.get("durationMs") as? Number)?.toLong() ?: 60_000
        MinisCameraXBridge.engine.enableTimeLapse(interval, duration) { err ->
          if (err == null) result.success(null) else result.error("TL_FAILED", err.message, null)
        }
      }
      "startMultiCam" -> {
        val args = call.arguments as? Map<*, *>
        val layout = (args?.get("layout") as? String) ?: "topRight"
        MinisCameraXBridge.engine.startMultiCam(layout) { err ->
          if (err == null) result.success(null) else result.error("MULTICAM_FAILED", err.message, null)
        }
      }
      "stopMultiCam" -> {
        MinisCameraXBridge.engine.stopMultiCam { path, err ->
          if (err == null) result.success(mapOf("path" to path))
          else result.error("MULTICAM_STOP_FAILED", err.message, null)
        }
      }
      "takePhoto" -> {
        MinisCameraXBridge.engine.takePicture { path, err ->
          if (err == null) result.success(mapOf("path" to path, "exif" to emptyMap<String, Any?>()))
          else result.error("CAPTURE_FAILED", err.message, null)
        }
      }
      "pauseRecord" -> { MinisCameraXBridge.engine.pauseRecording(); result.success(null) }
      "resumeRecord" -> { MinisCameraXBridge.engine.resumeRecording(); result.success(null) }
      "stopRecord" -> {
        MinisCameraXBridge.engine.stopRecording { path, dur, size, err ->
          if (err == null) result.success(mapOf("path" to path, "durationMs" to dur, "size" to size))
          else result.error("STOP_FAILED", err.message, null)
        }
      }
      "finalizeClips" -> {
        val args = call.arguments as? Map<*, *>
        val paths = (args?.get("clipPaths") as? List<*>)?.filterIsInstance<String>() ?: emptyList()
        MinisCameraXBridge.engine.finalizeClips(paths) { path, err ->
          if (err == null) result.success(mapOf("mergedPath" to path))
          else result.error("MERGE_FAILED", err.message, null)
        }
      }
      "setMic" -> {
        val args = call.arguments as? Map<*, *>
        val dev = args?.get("deviceId") as? String
        val gain = (args?.get("gain") as? Number)?.toDouble()
        MinisCameraXBridge.engine.setMic(dev, gain) { err ->
          if (err == null) result.success(null) else result.error("MIC_FAILED", err.message, null)
        }
      }
      "getCapabilities" -> result.success(MinisCameraXBridge.engine.capabilities())

      // Crash-recovery verbs.
      "probeRecovery" -> {
        MinisCameraXBridge.engine.probeRecovery { paths, totalMs ->
          if (paths.isEmpty()) result.success(null)
          else result.success(mapOf("segmentPaths" to paths, "totalDurationMs" to totalMs))
        }
      }
      "recoverAndFinalize" -> {
        val args = call.arguments as? Map<*, *>
        val outPath = args?.get("outPath") as? String
        MinisCameraXBridge.engine.recoverAndFinalize(outPath) { path, err ->
          if (err == null && path != null) result.success(mapOf("mergedPath" to path))
          else result.error("RECOVERY_FAILED", err?.message, null)
        }
      }
      "discardRecovery" -> {
        MinisCameraXBridge.engine.discardRecovery { err ->
          if (err == null) result.success(null) else result.error("DISCARD_FAILED", err.message, null)
        }
      }

      // Metadata + analysis + native frames toggles (handled below if/when impl lands).
      "listMics" -> {
        MinisCameraXBridge.engine.listMics { list -> result.success(mapOf("mics" to list)) }
      }

      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
      methodChannel?.setMethodCallHandler(null)
      methodChannel = null
      minisPermsChannel?.setMethodCallHandler(null); minisPermsChannel = null
      stateChannel?.setStreamHandler(null); stateChannel = null
      audioChannel?.setStreamHandler(null); audioChannel = null
      metaChannel?.setStreamHandler(null); metaChannel = null
      analysisChannel?.setStreamHandler(null); analysisChannel = null
      framesChannel?.setStreamHandler(null); framesChannel = null
      ImageEditPluginRouter.detach()
      AssetCatalog.bind(null)
      imgEditMemoryCallback?.let { cb ->
        (binding.applicationContext as? android.app.Application)?.unregisterComponentCallbacks(cb)
      }
      imgEditMemoryCallback = null
      paths?.dispose(); paths = null
      wakelock?.dispose(); wakelock = null
      permissions?.dispose(); permissions = null
      deviceInfo?.dispose(); deviceInfo = null
      mediaPicker?.dispose(); mediaPicker = null
      share?.dispose(); share = null
      playerEngine?.disposeAll(); playerEngine = null
      audioPlugin?.dispose(); audioPlugin = null
      videoEditEngine?.dispose(); videoEditEngine = null
      telemetry?.dispose(); telemetry = null
      filePicker = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
      val activity = binding.activity
      if (activity is FlutterFragmentActivity) {
          MinisCameraXBridge.setActivity(activity)
          minisCameraPerms.setActivity(activity)
          MinisCameraXBridge.engine.attachThermal(activity) { level ->
              stateSink?.success(
                  mapOf("state" to "preview", "code" to "THERMAL", "message" to "level=$level")
              )
          }
      }
      wakelock?.setActivity(activity)
      permissions?.setActivity(activity)
      mediaPicker?.setActivity(activity)
      share?.setActivity(activity)
      permissions?.let { binding.addRequestPermissionsResultListener(it) }
      mediaPicker?.let { binding.addActivityResultListener(it) }
      binding.addRequestPermissionsResultListener(this)
  }

  override fun onDetachedFromActivityForConfigChanges() {
      MinisCameraXBridge.setActivity(null)
      minisCameraPerms.setActivity(null)
      wakelock?.setActivity(null)
      permissions?.setActivity(null)
      mediaPicker?.setActivity(null)
      share?.setActivity(null)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
      val activity = binding.activity
      if (activity is FlutterFragmentActivity) {
          MinisCameraXBridge.setActivity(activity)
          minisCameraPerms.setActivity(activity)
      }
      wakelock?.setActivity(activity)
      permissions?.setActivity(activity)
      mediaPicker?.setActivity(activity)
      share?.setActivity(activity)
      permissions?.let { binding.addRequestPermissionsResultListener(it) }
      mediaPicker?.let { binding.addActivityResultListener(it) }
      binding.addRequestPermissionsResultListener(this)
  }

  override fun onDetachedFromActivity() {
      MinisCameraXBridge.setActivity(null)
      minisCameraPerms.setActivity(null)
      wakelock?.setActivity(null)
      permissions?.setActivity(null)
      mediaPicker?.setActivity(null)
      share?.setActivity(null)
  }

  override fun onRequestPermissionsResult(
      requestCode: Int,
      permissions: Array<out String>,
      grantResults: IntArray,
  ): Boolean = minisCameraPerms.onRequestResult(requestCode, grantResults)
}
