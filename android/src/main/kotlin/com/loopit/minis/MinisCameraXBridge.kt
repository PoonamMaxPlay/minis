package com.loopit.minis

import android.Manifest
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.video.FallbackStrategy
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

/**
 * CameraX + [MethodChannel] bridge for Minis native preview (see [MinisNativeCameraPlatformView]).
 */
@Suppress("TooManyFunctions")
object MinisCameraXBridge {
    private const val TAG = "MinisCameraXBridge"

    private val mainHandler = Handler(Looper.getMainLooper())

    private var activityRef: WeakReference<FlutterFragmentActivity>? = null

    @Volatile
    private var previewView: PreviewView? = null

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null

    private var previewUseCase: Preview? = null
    private var videoCaptureUseCase: VideoCapture<Recorder>? = null
    private var imageCaptureUseCase: ImageCapture? = null

    private var cameraSelector: CameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
    private var torchOn = false
    private var recordWithAudioEnabled = true
    private var qualityTierState = 2

    private val isRecordingAtomic = AtomicBoolean(false)
    private var activeRecording: Recording? = null

    /** Completed when [VideoRecordEvent.Finalize] arrives after [Recording.stop]. */
    private var pendingStopResult: MethodChannel.Result? = null

    private var lastVideoPath: String? = null

    fun setActivity(activity: FlutterFragmentActivity?) {
        activityRef = if (activity != null) WeakReference(activity) else null
    }

    private fun currentActivity(): FlutterFragmentActivity? = activityRef?.get()

    fun attachPreviewView(view: PreviewView) {
        mainHandler.post {
            previewView = view
            tryRebindAfterPreviewAttached()
        }
    }

    fun detachPreviewView(view: PreviewView) {
        mainHandler.post {
            if (previewView === view) {
                previewView = null
            }
            runCatching { cameraProvider?.unbindAll() }
            camera = null
            previewUseCase = null
            videoCaptureUseCase = null
            imageCaptureUseCase = null
        }
    }

    private fun tryRebindAfterPreviewAttached() {
        val act = currentActivity() ?: return
        val cp = cameraProvider ?: return
        val pv = previewView ?: return
        runCatching {
            bindUseCases(act, cp, pv)
        }.onFailure { Log.w(TAG, "rebind after attach failed: ${it.message}") }
    }

    fun warmUp(result: MethodChannel.Result) {
        val act = currentActivity()
        if (act == null) {
            result.error("NO_ACTIVITY", "Activity not set", null)
            return
        }
        val future = ProcessCameraProvider.getInstance(act)
        future.addListener(
            {
                try {
                    cameraProvider = future.get()
                    result.success(null)
                } catch (e: Exception) {
                    Log.e(TAG, "warmUp", e)
                    result.error("WARMUP_FAILED", e.message, null)
                }
            },
            ContextCompat.getMainExecutor(act),
        )
    }

    fun bind(qualityTier: Int, enableAudio: Boolean, result: MethodChannel.Result) {
        mainHandler.post {
            val act = currentActivity()
            val pv = previewView
            val cp = cameraProvider
            if (act == null) {
                result.error("NO_ACTIVITY", "Activity not set", null)
                return@post
            }
            if (pv == null) {
                result.error("NO_PREVIEW", "Preview not ready", null)
                return@post
            }
            if (cp == null) {
                result.error("NOT_WARMED", "Call warmUp first", null)
                return@post
            }
            qualityTierState = qualityTier
            recordWithAudioEnabled = enableAudio
            try {
                bindUseCases(act, cp, pv)
                result.success(null)
            } catch (e: Exception) {
                Log.e(TAG, "bind", e)
                result.error("BIND_FAILED", e.message, null)
            }
        }
    }

    private fun bindUseCases(
        act: FlutterFragmentActivity,
        provider: ProcessCameraProvider,
        pv: PreviewView,
    ) {
        provider.unbindAll()
        camera = null

        val quality = when (qualityTierState) {
            0 -> Quality.SD
            1 -> Quality.HD
            2 -> Quality.FHD
            else -> Quality.HD
        }
        val qs = QualitySelector.from(
            quality,
            FallbackStrategy.higherQualityOrLowerThan(quality),
        )

        val recorder = Recorder.Builder()
            .setQualitySelector(qs)
            .build()

        videoCaptureUseCase = VideoCapture.withOutput(recorder)

        imageCaptureUseCase = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()

        previewUseCase = Preview.Builder().build().also {
            it.setSurfaceProvider(pv.surfaceProvider)
        }

        val cam = provider.bindToLifecycle(
            act as LifecycleOwner,
            cameraSelector,
            previewUseCase!!,
            videoCaptureUseCase!!,
            imageCaptureUseCase!!,
        )
        camera = cam
        applyTorch(cam)
        Log.i(TAG, "bound selector=$cameraSelector tier=$qualityTierState")
    }

    fun startRecording(outputPathHint: String?, result: MethodChannel.Result) {
        mainHandler.post {
            try {
                if (!isRecordingAtomic.compareAndSet(false, true)) {
                    result.error("RECORDING", "Already recording", null)
                    return@post
                }
                val act = currentActivity()
                val vc = videoCaptureUseCase
                if (act == null || vc == null || cameraProvider == null) {
                    isRecordingAtomic.set(false)
                    result.error("NOT_READY", "Camera not bound", null)
                    return@post
                }

                lastVideoPath = null
                pendingStopResult = null

                val dir = File(act.cacheDir, "minis_native_capture").apply { mkdirs() }
                val outFile = if (!outputPathHint.isNullOrBlank()) {
                    File(outputPathHint)
                } else {
                    File(dir, "minis_${System.currentTimeMillis()}.mp4")
                }

                val fileOptions = FileOutputOptions.Builder(outFile).build()
                val pending = vc.output.prepareRecording(act, fileOptions)

                val starter = if (recordWithAudioEnabled && hasMicPermission(act)) {
                    pending.withAudioEnabled()
                } else {
                    pending
                }

                activeRecording = starter.start(
                    ContextCompat.getMainExecutor(act),
                ) { event ->
                    when (event) {
                        is VideoRecordEvent.Status -> Unit
                        is VideoRecordEvent.Finalize -> {
                            if (event.hasError()) {
                                Log.e(TAG, "finalize cause=${event.cause}")
                                pendingStopResult?.error(
                                    "RECORD_FAILED",
                                    event.cause?.message ?: "record error",
                                    null,
                                )
                            } else {
                                lastVideoPath = outFile.absolutePath
                                pendingStopResult?.success(lastVideoPath)
                            }
                            pendingStopResult = null
                            activeRecording = null
                            isRecordingAtomic.set(false)
                        }
                    }
                }
                result.success(null)
            } catch (e: Exception) {
                isRecordingAtomic.set(false)
                Log.e(TAG, "startRecording", e)
                result.error("START_FAILED", e.message, null)
            }
        }
    }

    fun stopRecording(result: MethodChannel.Result) {
        mainHandler.post {
            val rec = activeRecording
            if (rec == null) {
                result.error("NOT_RECORDING", "No active recording", null)
                return@post
            }
            pendingStopResult = result
            runCatching { rec.stop() }
        }
    }

    fun takePicture(result: MethodChannel.Result) {
        mainHandler.post {
            val act = currentActivity()
            val ic = imageCaptureUseCase
            if (act == null || ic == null) {
                result.error("NOT_READY", "Camera not bound", null)
                return@post
            }
            val dir = File(act.cacheDir, "minis_native_capture").apply { mkdirs() }
            val photoFile = File(dir, "minis_${System.currentTimeMillis()}.jpg")
            val opts = ImageCapture.OutputFileOptions.Builder(photoFile).build()
            ic.takePicture(
                opts,
                ContextCompat.getMainExecutor(act),
                object : ImageCapture.OnImageSavedCallback {
                    override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                        result.success(photoFile.absolutePath)
                    }

                    override fun onError(exception: ImageCaptureException) {
                        Log.e(TAG, "takePicture", exception)
                        result.error("CAPTURE_FAILED", exception.message, null)
                    }
                },
            )
        }
    }

    fun switchCamera(result: MethodChannel.Result) {
        mainHandler.post {
            val act = currentActivity()
            val pv = previewView
            val cp = cameraProvider
            if (act == null || pv == null || cp == null) {
                result.error("NOT_READY", "Camera not bound", null)
                return@post
            }
            cameraSelector = if (cameraSelector == CameraSelector.DEFAULT_BACK_CAMERA) {
                CameraSelector.DEFAULT_FRONT_CAMERA
            } else {
                CameraSelector.DEFAULT_BACK_CAMERA
            }
            torchOn = false
            try {
                bindUseCases(act, cp, pv)
                result.success(null)
            } catch (e: Exception) {
                Log.e(TAG, "switchCamera", e)
                result.error("SWITCH_FAILED", e.message, null)
            }
        }
    }

    fun setTorchEnabled(on: Boolean, result: MethodChannel.Result) {
        mainHandler.post {
            torchOn = on
            val cam = camera
            if (cam != null && cam.cameraInfo.hasFlashUnit()) {
                cam.cameraControl.enableTorch(on)
            }
            result.success(null)
        }
    }

    private fun applyTorch(cam: Camera) {
        if (!cam.cameraInfo.hasFlashUnit()) return
        cam.cameraControl.enableTorch(torchOn)
    }

    fun getMinZoom(result: MethodChannel.Result) {
        mainHandler.post {
            val z = camera?.cameraInfo?.zoomState?.value
            val min = z?.minZoomRatio?.toDouble() ?: 1.0
            result.success(min)
        }
    }

    fun getMaxZoom(result: MethodChannel.Result) {
        mainHandler.post {
            val z = camera?.cameraInfo?.zoomState?.value
            val max = z?.maxZoomRatio?.toDouble() ?: 1.0
            result.success(max)
        }
    }

    fun setZoomLevel(ratio: Double, result: MethodChannel.Result) {
        mainHandler.post {
            val cam = camera ?: run {
                result.error("NOT_READY", "Camera not bound", null)
                return@post
            }
            val z = cam.cameraInfo.zoomState.value ?: run {
                result.success(null)
                return@post
            }
            val clamped = ratio.coerceIn(
                z.minZoomRatio.toDouble(),
                z.maxZoomRatio.toDouble(),
            )
            cam.cameraControl.setZoomRatio(clamped.toFloat())
            result.success(null)
        }
    }

    fun setRecordWithAudio(enabled: Boolean, result: MethodChannel.Result) {
        mainHandler.post {
            recordWithAudioEnabled = enabled
            result.success(null)
        }
    }

    fun disposeForFlutter() {
        mainHandler.post {
            runCatching { activeRecording?.stop() }
            activeRecording = null
            pendingStopResult = null
            isRecordingAtomic.set(false)

            runCatching { cameraProvider?.unbindAll() }
            camera = null
            previewUseCase = null
            videoCaptureUseCase = null
            imageCaptureUseCase = null
        }
    }

    private fun hasMicPermission(act: FlutterFragmentActivity): Boolean =
        ContextCompat.checkSelfPermission(act, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
}
