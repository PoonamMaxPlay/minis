package com.loopit.minis

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

class LoopitMinisPlugin: FlutterPlugin, ActivityAware {
  private var methodChannel: MethodChannel? = null

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "minis_preview_player", 
        MinisPreviewPlayerFactory(flutterPluginBinding.binaryMessenger)
    )
    flutterPluginBinding.platformViewRegistry.registerViewFactory(
        "minis_native_camera",
        MinisNativeCameraPlatformViewFactory()
    )

    methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.buzzit.social/minis_native_camera")
    methodChannel?.setMethodCallHandler { call, result ->
        when (call.method) {
            "warmUp" -> MinisCameraXBridge.warmUp(result)
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
            else -> result.notImplemented()
        }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
      methodChannel?.setMethodCallHandler(null)
      methodChannel = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
      val activity = binding.activity
      if (activity is FlutterFragmentActivity) {
          MinisCameraXBridge.setActivity(activity)
      }
  }

  override fun onDetachedFromActivityForConfigChanges() {
      MinisCameraXBridge.setActivity(null)
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
      val activity = binding.activity
      if (activity is FlutterFragmentActivity) {
          MinisCameraXBridge.setActivity(activity)
      }
  }

  override fun onDetachedFromActivity() {
      MinisCameraXBridge.setActivity(null)
  }
}
