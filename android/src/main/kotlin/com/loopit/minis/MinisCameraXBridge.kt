package com.loopit.minis

import androidx.camera.view.PreviewView
import com.loopit.minis.camera.CameraXEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

/**
 * Thin compat facade preserved for callers that still reference the old
 * MinisCameraXBridge symbol. All real logic lives in
 * [com.loopit.minis.camera.CameraXEngine].
 *
 * The plugin holds the singleton engine; this object forwards a small subset of
 * legacy methods (warmUp/bind/start/stop/picture/torch/zoom/dispose/etc.).
 */
object MinisCameraXBridge {
    @Volatile var engine: CameraXEngine = CameraXEngine()

    fun setActivity(activity: FlutterFragmentActivity?) {
        engine.setActivity(activity)
    }

    fun attachPreviewView(view: PreviewView) {
        engine.attachPrimaryPreview(view)
    }

    fun detachPreviewView(view: PreviewView) {
        engine.detachPrimaryPreview(view)
    }

    fun warmUp(result: MethodChannel.Result) {
        engine.warmUp { err ->
            if (err == null) result.success(null) else result.error("WARMUP_FAILED", err.message, null)
        }
    }

    fun bind(qualityTier: Int, enableAudio: Boolean, result: MethodChannel.Result) {
        engine.bind(qualityTier, enableAudio) { err ->
            when (err) {
                null -> result.success(null)
                is CameraXEngine.NoPreviewException -> result.error("NO_PREVIEW", "Preview not ready", null)
                else -> result.error("BIND_FAILED", err.message, null)
            }
        }
    }

    fun startRecording(outputPathHint: String?, result: MethodChannel.Result) {
        engine.startRecording(outputPathHint) { _, err ->
            if (err == null) result.success(null) else result.error("START_FAILED", err.message, null)
        }
    }

    fun stopRecording(result: MethodChannel.Result) {
        engine.stopRecording { path, _, _, err ->
            if (err == null) result.success(path) else result.error("STOP_FAILED", err.message, null)
        }
    }

    fun takePicture(result: MethodChannel.Result) {
        engine.takePicture { path, err ->
            if (err == null) result.success(path) else result.error("CAPTURE_FAILED", err.message, null)
        }
    }

    fun switchCamera(result: MethodChannel.Result) {
        engine.switchCamera { err ->
            if (err == null) result.success(null) else result.error("SWITCH_FAILED", err.message, null)
        }
    }

    fun setTorchEnabled(on: Boolean, result: MethodChannel.Result) {
        engine.setTorch(on) { err ->
            if (err == null) result.success(null) else result.error("TORCH_FAILED", err.message, null)
        }
    }

    fun getMinZoom(result: MethodChannel.Result) {
        result.success(engine.getZoomBounds().first)
    }

    fun getMaxZoom(result: MethodChannel.Result) {
        result.success(engine.getZoomBounds().second)
    }

    fun setZoomLevel(ratio: Double, result: MethodChannel.Result) {
        engine.setZoomRatio(ratio) { err ->
            if (err == null) result.success(null) else result.error("ZOOM_FAILED", err.message, null)
        }
    }

    fun setRecordWithAudio(enabled: Boolean, result: MethodChannel.Result) {
        engine.setRecordWithAudio(enabled) { err ->
            if (err == null) result.success(null) else result.error("MIC_FAILED", err.message, null)
        }
    }

    fun disposeForFlutter() {
        engine.release()
    }
}
