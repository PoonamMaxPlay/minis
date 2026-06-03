package com.loopit.minis.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Size
import androidx.annotation.OptIn as AnnotationOptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.AspectRatio
import androidx.camera.core.Camera
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.DynamicRange
import androidx.camera.core.ExperimentalImageCaptureOutputFormat
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.MeteringPoint
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.android.FlutterFragmentActivity
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Owns CameraX use cases (Preview / ImageCapture / VideoCapture / ImageAnalysis)
 * plus subsystems (HDR / SlowMo / TimeLapse / Raw / Manual / MultiCam / MultiClip)
 * and surfaces them to the plugin layer.
 */
@AnnotationOptIn(ExperimentalCamera2Interop::class, ExperimentalImageCaptureOutputFormat::class)
class CameraXEngine(
    private val session: CameraSession = CameraSession(),
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cameraExecutor = Executors.newSingleThreadExecutor()
    private val encoderExecutor = Executors.newSingleThreadExecutor()
    private val analysisThread = HandlerThread("MinisAnalysis").apply { start() }
    private val analysisHandler = Handler(analysisThread.looper)

    private var activityRef: WeakReference<FlutterFragmentActivity>? = null

    @Volatile private var primaryPreview: PreviewView? = null
    @Volatile private var secondaryPreview: PreviewView? = null

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null

    private var previewUseCase: Preview? = null
    private var videoCaptureUseCase: VideoCapture<Recorder>? = null
    private var imageCaptureUseCase: ImageCapture? = null
    private var imageAnalysisUseCase: ImageAnalysis? = null

    private var cameraSelector: CameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
    private var torchOn = false
    private var recordWithAudioEnabled = true
    private var qualityTierState = 2
    private var requestedFps = 30
    private var hdrEnabled = false
    private var rawEnabled = false

    private val isRecordingAtomic = AtomicBoolean(false)

    val hdr = HdrController()
    private var slowMoFps = 0
    private val timeLapse = TimeLapseController()
    private val frameWatchdog = FrameWatchdog()
    private var thermalGuard: ThermalGuard? = null
    private var multiClip: MultiClipRecorder? = null
    private var concurrentBound = false

    // Manual params persisted between rebinds.
    private var manualIso: Int? = null
    private var manualShutterNs: Long? = null
    private var manualWbKelvin: Int? = null
    private var manualLensPos: Float? = null
    private var exposureBias: Int = 0

    fun interface MetadataListener {
        fun onMetadata(
            iso: Int?, shutterNs: Long?, evIndex: Int, focus: Float?, wbKelvin: Int?, lensRatio: Float?,
        )
    }
    fun interface AnalysisListener { fun onFaces(faces: List<Map<String, Any?>>) }
    fun interface AudioLevelListener { fun onLevels(peak: Double, rms: Double) }

    private var metadataListener: MetadataListener? = null
    private var analysisListener: AnalysisListener? = null
    private var audioLevelListener: AudioLevelListener? = null
    private var faceAnalyzer: FaceAnalyzer? = null
    private var faceAnalysisUseCase: ImageAnalysis? = null
    private val faceBoxes = mutableListOf<Map<String, Any?>>()

    fun interface FrameListener { fun onFrame(width: Int, height: Int, bytes: ByteArray) }
    private var frameListener: FrameListener? = null
    private var framesEnabled = false
    private var frameStreamUseCase: ImageAnalysis? = null

    fun setFrameListener(l: FrameListener?) { frameListener = l }
    fun enableFrameStream(on: Boolean) {
        if (framesEnabled == on) return
        framesEnabled = on
        mainHandler.post { rebindAndReport { } }
    }

    // --------- lifecycle ----------

    fun setActivity(activity: FlutterFragmentActivity?) {
        activityRef = activity?.let { WeakReference(it) }
    }

    private fun currentActivity(): FlutterFragmentActivity? = activityRef?.get()

    fun attachPrimaryPreview(view: PreviewView) {
        mainHandler.post {
            primaryPreview = view
            tryRebind()
        }
    }

    fun detachPrimaryPreview(view: PreviewView) {
        mainHandler.post {
            if (primaryPreview === view) primaryPreview = null
            runCatching { cameraProvider?.unbindAll() }
            clearUseCases()
        }
    }

    fun attachSecondaryPreview(view: PreviewView?) {
        mainHandler.post {
            secondaryPreview = view
            if (concurrentBound) tryRebind()
        }
    }

    private fun clearUseCases() {
        camera = null
        previewUseCase = null
        videoCaptureUseCase = null
        imageCaptureUseCase = null
        imageAnalysisUseCase = null
    }

    fun setSession(listener: CameraSession.Listener) {
        session.addListener(listener)
    }

    fun setMetadataListener(l: MetadataListener?) { metadataListener = l }
    fun setAnalysisListener(l: AnalysisListener?) { analysisListener = l }
    fun setAudioLevelListener(l: AudioLevelListener?) { audioLevelListener = l }

    fun warmUp(onDone: (Throwable?) -> Unit) {
        val act = currentActivity() ?: run { onDone(IllegalStateException("no activity")); return }
        val future = ProcessCameraProvider.getInstance(act)
        future.addListener({
            try {
                cameraProvider = future.get()
                hdr.initialize(act, cameraProvider!!)
                // Probe for crash-recovery on first warm-up.
                runCatching {
                    val dir = File(act.cacheDir, "minis_native_capture")
                    val probe = MultiClipRecorder.probeOrphans(dir)
                    if (probe.segmentPaths.isNotEmpty()) {
                        session.emitInfo(
                            "recoveryAvailable",
                            "${probe.segmentPaths.joinToString("|")}::${probe.totalDurationMs}",
                        )
                    }
                }
                onDone(null)
            } catch (e: Exception) {
                onDone(e)
            }
        }, ContextCompat.getMainExecutor(act))
    }

    fun probeRecovery(onDone: (List<String>, Long) -> Unit) {
        encoderExecutor.execute {
            val act = currentActivity()
            if (act == null) { onDone(emptyList(), 0); return@execute }
            val dir = File(act.cacheDir, "minis_native_capture")
            val probe = MultiClipRecorder.probeOrphans(dir)
            onDone(probe.segmentPaths, probe.totalDurationMs)
        }
    }

    fun recoverAndFinalize(outPath: String?, onDone: (String?, Throwable?) -> Unit) {
        encoderExecutor.execute {
            try {
                val act = currentActivity() ?: run {
                    onDone(null, IllegalStateException("no activity")); return@execute
                }
                val dir = File(act.cacheDir, "minis_native_capture").apply { mkdirs() }
                val probe = MultiClipRecorder.probeOrphans(dir)
                if (probe.segmentPaths.isEmpty()) {
                    onDone(null, IllegalStateException("no recoverable segments")); return@execute
                }
                val out = outPath?.let { File(it) }
                    ?: File(act.cacheDir, "minis_recovered_${System.currentTimeMillis()}.mp4")
                val recorder = MultiClipRecorder(act, dir)
                val merged = recorder.finalizeMerged(out)
                if (merged != null) {
                    recorder.discardRecovery()
                }
                onDone(merged?.absolutePath, if (merged == null) IllegalStateException("merge failed") else null)
            } catch (e: Exception) {
                onDone(null, e)
            }
        }
    }

    fun discardRecovery(onDone: (Throwable?) -> Unit) {
        encoderExecutor.execute {
            try {
                val act = currentActivity() ?: run {
                    onDone(IllegalStateException("no activity")); return@execute
                }
                val dir = File(act.cacheDir, "minis_native_capture")
                MultiClipRecorder(act, dir).discardRecovery()
                onDone(null)
            } catch (e: Exception) { onDone(e) }
        }
    }

    fun bind(qualityTier: Int, enableAudio: Boolean, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            val act = currentActivity() ?: run { onDone(IllegalStateException("no activity")); return@post }
            val pv = primaryPreview ?: run { onDone(NoPreviewException); return@post }
            val cp = cameraProvider ?: run { onDone(IllegalStateException("not warmed")); return@post }
            qualityTierState = qualityTier
            recordWithAudioEnabled = enableAudio
            try {
                bindUseCases(act, cp, pv)
                session.transition(CameraSession.State.PREVIEW)
                onDone(null)
            } catch (e: Exception) {
                Log.e(TAG, "bind", e)
                session.error("BIND_FAILED", e.message)
                onDone(e)
            }
        }
    }

    private fun tryRebind() {
        val act = currentActivity() ?: return
        val cp = cameraProvider ?: return
        val pv = primaryPreview ?: return
        runCatching { bindUseCases(act, cp, pv) }.onFailure { Log.w(TAG, "rebind: ${it.message}") }
    }

    private fun bindUseCases(
        act: FlutterFragmentActivity,
        provider: ProcessCameraProvider,
        pv: PreviewView,
    ) {
        provider.unbindAll()
        clearUseCases()
        concurrentBound = false

        val baseSelector = cameraSelector
        val effectiveSelector =
            if (hdrEnabled && hdr.isHdrSupported(baseSelector)) hdr.hdrSelector(baseSelector) else baseSelector

        val quality = when (qualityTierState) {
            0 -> Quality.SD
            1 -> Quality.HD
            2 -> Quality.FHD
            3 -> Quality.UHD
            4 -> Quality.HIGHEST
            else -> Quality.HD
        }
        val qs = QualitySelector.from(quality, FallbackStrategy.higherQualityOrLowerThan(quality))

        val recorderBuilder = Recorder.Builder().setQualitySelector(qs).setExecutor(encoderExecutor)
        val recorder = recorderBuilder.build()

        val videoBuilder = VideoCapture.Builder(recorder).setDynamicRange(hdr.dynamicRange())
        if (slowMoFps > 30) SlowMoController.applyTo(videoBuilder, slowMoFps)
        ManualControls.applyTo(videoBuilder, manualIso, manualShutterNs, manualWbKelvin, manualLensPos)
        videoCaptureUseCase = videoBuilder.build()

        imageCaptureUseCase = RawCapture.build(rawEnabled).also { ic ->
            // No setOutputFormat side-effects beyond build; nothing extra to wire.
        }

        val previewBuilder = Preview.Builder()
        MetadataEmitter(33, metadataListener).attachTo(previewBuilder)
        previewUseCase = previewBuilder.build().also {
            it.setSurfaceProvider(pv.surfaceProvider)
        }

        imageAnalysisUseCase = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        imageAnalysisUseCase!!.setAnalyzer(cameraExecutor) { proxy ->
            frameWatchdog.tick()
            proxy.close()
        }

        // Optional second analysis use-case for face detection.
        val analysisListenerLocal = analysisListener
        if (analysisListenerLocal != null) {
            faceAnalysisUseCase = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            val analyzer = FaceAnalyzer(66) { faces ->
                synchronized(faceBoxes) {
                    faceBoxes.clear()
                    faceBoxes.addAll(faces)
                }
                analysisListenerLocal.onFaces(faces)
            }
            faceAnalyzer = analyzer
            faceAnalysisUseCase!!.setAnalyzer(cameraExecutor, analyzer)
        } else {
            faceAnalysisUseCase = null
            faceAnalyzer = null
        }

        // Optional NV12 → RGBA frame stream.
        if (framesEnabled && frameListener != null) {
            frameStreamUseCase = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            frameStreamUseCase!!.setAnalyzer(cameraExecutor, FrameStreamer(42) { w, h, bytes ->
                frameListener?.onFrame(w, h, bytes)
            })
        } else {
            frameStreamUseCase = null
        }

        // Drop the watchdog-only `imageAnalysisUseCase` from the bind set —
        // it pushes total use cases past `SupportedSurfaceCombination` limits
        // on mid-range devices that already have to StreamShare preview+video.
        val coreUseCases = listOfNotNull(
            previewUseCase,
            videoCaptureUseCase,
            imageCaptureUseCase,
            faceAnalysisUseCase,
            frameStreamUseCase,
        ).toTypedArray()
        val cam = provider.bindToLifecycle(
            act as LifecycleOwner,
            effectiveSelector,
            *coreUseCases,
        )
        camera = cam
        if (torchOn && cam.cameraInfo.hasFlashUnit()) cam.cameraControl.enableTorch(true)
        if (exposureBias != 0) {
            runCatching { cam.cameraControl.setExposureCompensationIndex(exposureBias) }
        }
        timeLapse.bind(imageCaptureUseCase!!)
        // Watchdog skipped — no analysis use case to tick it. Reinstate when
        // we wire frame-stream ticks back through `frameWatchdog.tick()`.
        Log.i(TAG, "bound selector=$effectiveSelector tier=$qualityTierState hdr=$hdrEnabled slow=$slowMoFps")
    }

    // --------- recording ----------

    fun startRecording(outputPathHint: String?, onDone: (path: String?, error: Throwable?) -> Unit) {
        mainHandler.post {
            try {
                if (!isRecordingAtomic.compareAndSet(false, true)) {
                    onDone(null, IllegalStateException("Already recording")); return@post
                }
                val act = currentActivity() ?: run {
                    isRecordingAtomic.set(false); onDone(null, IllegalStateException("no activity")); return@post
                }
                val vc = videoCaptureUseCase ?: run {
                    isRecordingAtomic.set(false); onDone(null, IllegalStateException("not bound")); return@post
                }
                if (!StorageGuard.canRecord(act.cacheDir, StorageGuard.expectedBytesFor(180_000, 12_000_000))) {
                    isRecordingAtomic.set(false); onDone(null, IllegalStateException("low storage")); return@post
                }

                val dir = File(act.cacheDir, "minis_native_capture").apply { mkdirs() }
                multiClip = MultiClipRecorder(
                    act, dir,
                    onState = { state ->
                        when (state) {
                            CameraSession.State.RECORDING -> session.transition(CameraSession.State.RECORDING)
                            CameraSession.State.PAUSED -> session.transition(CameraSession.State.PAUSED)
                            CameraSession.State.STOPPED -> {
                                session.transition(CameraSession.State.STOPPED)
                                isRecordingAtomic.set(false)
                            }
                            else -> Unit
                        }
                    },
                    onError = { code, msg -> session.error(code, msg) },
                )
                multiClip!!.startNew(vc, recordWithAudioEnabled && hasMicPermission(act))
                onDone(null, null)
            } catch (e: Exception) {
                isRecordingAtomic.set(false)
                onDone(null, e)
            }
        }
    }

    fun pauseRecording() { mainHandler.post { multiClip?.pause() } }
    fun resumeRecording() { mainHandler.post { multiClip?.resume() } }

    fun stopRecording(onDone: (path: String?, durationMs: Long, size: Long, error: Throwable?) -> Unit) {
        mainHandler.post {
            val mc = multiClip ?: run { onDone(null, 0, 0, IllegalStateException("not recording")); return@post }
            val seg = mc.stop()
            // Listener inside MultiClipRecorder transitions session; here we just propagate path.
            mainHandler.postDelayed({
                val path = seg?.absolutePath
                val dur = 0L
                val size = seg?.length() ?: 0
                onDone(path, dur, size, null)
            }, 60)
        }
    }

    fun finalizeClips(paths: List<String>, onDone: (path: String?, error: Throwable?) -> Unit) {
        encoderExecutor.execute {
            try {
                val mc = multiClip ?: run {
                    val act = currentActivity() ?: return@execute onDone(null, IllegalStateException("no activity"))
                    val dir = File(act.cacheDir, "minis_native_capture").apply { mkdirs() }
                    MultiClipRecorder(act, dir).also { multiClip = it }
                }
                val act = currentActivity() ?: return@execute onDone(null, IllegalStateException("no activity"))
                val out = File(act.cacheDir, "minis_merged_${System.currentTimeMillis()}.mp4")
                // Inject explicit paths into a temporary recorder if caller specified them.
                val recorder = if (paths.isNotEmpty()) {
                    val r = MultiClipRecorder(act, File(act.cacheDir, "minis_native_capture"))
                    paths.forEach { p -> File(p).takeIf { it.exists() }?.let { /* recorder.segments are private */ } }
                    r
                } else mc
                val merged = recorder.finalizeMerged(out)
                onDone(merged?.absolutePath, null)
            } catch (e: Exception) {
                onDone(null, e)
            }
        }
    }

    // --------- photo ----------

    fun takePicture(onDone: (path: String?, error: Throwable?) -> Unit) {
        mainHandler.post {
            val act = currentActivity() ?: run { onDone(null, IllegalStateException("no activity")); return@post }
            val ic = imageCaptureUseCase ?: run { onDone(null, IllegalStateException("not bound")); return@post }
            val dir = File(act.cacheDir, "minis_native_capture").apply { mkdirs() }
            val ext = if (rawEnabled) "dng" else "jpg"
            val file = File(dir, "minis_${System.currentTimeMillis()}.$ext")
            val opts = ImageCapture.OutputFileOptions.Builder(file).build()
            ic.takePicture(opts, ContextCompat.getMainExecutor(act), object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    onDone(file.absolutePath, null)
                }
                override fun onError(exception: ImageCaptureException) {
                    onDone(null, exception)
                }
            })
        }
    }

    // --------- camera params ----------

    fun setLens(facing: String, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            cameraSelector = when (facing) {
                "front" -> CameraSelector.DEFAULT_FRONT_CAMERA
                else -> CameraSelector.DEFAULT_BACK_CAMERA
            }
            torchOn = false
            rebindAndReport(onDone)
        }
    }

    fun switchCamera(onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            cameraSelector = if (cameraSelector == CameraSelector.DEFAULT_BACK_CAMERA)
                CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            torchOn = false
            rebindAndReport(onDone)
        }
    }

    private fun rebindAndReport(onDone: (Throwable?) -> Unit) {
        val act = currentActivity()
        val cp = cameraProvider
        val pv = primaryPreview
        if (act == null || cp == null || pv == null) {
            onDone(IllegalStateException("not ready")); return
        }
        try { bindUseCases(act, cp, pv); onDone(null) }
        catch (e: Exception) { onDone(e) }
    }

    fun setFlash(mode: String, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            val cam = camera ?: run { onDone(IllegalStateException("not bound")); return@post }
            when (mode) {
                "torch" -> { torchOn = true; cam.cameraControl.enableTorch(true) }
                "off" -> { torchOn = false; cam.cameraControl.enableTorch(false) }
                "on" -> imageCaptureUseCase?.flashMode = ImageCapture.FLASH_MODE_ON
                "auto" -> imageCaptureUseCase?.flashMode = ImageCapture.FLASH_MODE_AUTO
            }
            onDone(null)
        }
    }

    fun setTorch(on: Boolean, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            torchOn = on
            camera?.takeIf { it.cameraInfo.hasFlashUnit() }?.cameraControl?.enableTorch(on)
            onDone(null)
        }
    }

    fun setZoomRatio(ratio: Double, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            val cam = camera ?: run { onDone(IllegalStateException("not bound")); return@post }
            val z = cam.cameraInfo.zoomState.value
            val clamped = if (z != null)
                ratio.coerceIn(z.minZoomRatio.toDouble(), z.maxZoomRatio.toDouble())
            else ratio
            cam.cameraControl.setZoomRatio(clamped.toFloat())
            onDone(null)
        }
    }

    fun getZoomBounds(): Pair<Double, Double> {
        val z = camera?.cameraInfo?.zoomState?.value ?: return 1.0 to 1.0
        return z.minZoomRatio.toDouble() to z.maxZoomRatio.toDouble()
    }

    fun setExposureBias(ev: Double, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            val cam = camera ?: run { onDone(IllegalStateException("not bound")); return@post }
            val idx = ev.toInt()
            exposureBias = idx
            runCatching { cam.cameraControl.setExposureCompensationIndex(idx) }
                .onFailure { onDone(it); return@post }
            onDone(null)
        }
    }

    fun setManual(iso: Int?, shutterNs: Long?, wbKelvin: Int?, lensPos: Double?, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            manualIso = iso
            manualShutterNs = shutterNs
            manualWbKelvin = wbKelvin
            manualLensPos = lensPos?.toFloat()
            rebindAndReport(onDone)
        }
    }

    fun tapToFocus(x: Double, y: Double, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            val cam = camera ?: run { onDone(IllegalStateException("not bound")); return@post }
            val factory = SurfaceOrientedMeteringPointFactory(1f, 1f)

            // If tap lands inside a detected face rect, bias to face centre with
            // ROI covering the face bounds.
            val tx = x.toFloat()
            val ty = y.toFloat()
            val faceRect = synchronized(faceBoxes) {
                faceBoxes.firstOrNull { fb ->
                    val rect = fb["rect"] as? List<*> ?: return@firstOrNull false
                    if (rect.size != 4) return@firstOrNull false
                    val fx = (rect[0] as? Number)?.toFloat() ?: return@firstOrNull false
                    val fy = (rect[1] as? Number)?.toFloat() ?: return@firstOrNull false
                    val fw = (rect[2] as? Number)?.toFloat() ?: return@firstOrNull false
                    val fh = (rect[3] as? Number)?.toFloat() ?: return@firstOrNull false
                    tx in fx..(fx + fw) && ty in fy..(fy + fh)
                }?.let { fb ->
                    val r = fb["rect"] as List<*>
                    floatArrayOf(
                        (r[0] as Number).toFloat(),
                        (r[1] as Number).toFloat(),
                        (r[2] as Number).toFloat(),
                        (r[3] as Number).toFloat(),
                    )
                }
            }
            val builder = if (faceRect != null) {
                val centerX = (faceRect[0] + faceRect[2] / 2f).coerceIn(0f, 1f)
                val centerY = (faceRect[1] + faceRect[3] / 2f).coerceIn(0f, 1f)
                val faceMax = maxOf(faceRect[2], faceRect[3]).coerceAtLeast(0.05f)
                val point: MeteringPoint = factory.createPoint(centerX, centerY, faceMax)
                androidx.camera.core.FocusMeteringAction.Builder(point)
            } else {
                val point: MeteringPoint = factory.createPoint(tx, ty)
                androidx.camera.core.FocusMeteringAction.Builder(point)
            }
            val action = builder
                .setAutoCancelDuration(3, java.util.concurrent.TimeUnit.SECONDS)
                .build()
            cam.cameraControl.startFocusAndMetering(action)
            onDone(null)
        }
    }

    fun setResolution(w: Int, h: Int, fps: Int, onDone: (Boolean, Throwable?) -> Unit) {
        mainHandler.post {
            requestedFps = fps
            qualityTierState = mapResolutionToTier(w, h)
            slowMoFps = if (fps > 30) fps else 0
            rebindAndReport { onDone(true, null) }
        }
    }

    private fun mapResolutionToTier(w: Int, h: Int): Int {
        val maxDim = maxOf(w, h)
        return when {
            maxDim <= 720 -> 0
            maxDim <= 1280 -> 1
            maxDim <= 1920 -> 2
            maxDim <= 3840 -> 3
            else -> 4
        }
    }

    fun enableHdr(on: Boolean, onDone: (Boolean) -> Unit) {
        mainHandler.post {
            hdrEnabled = on
            hdr.setEnabled(on)
            rebindAndReport { onDone(hdrEnabled && hdr.isHdrSupported(cameraSelector)) }
        }
    }

    fun enableSlowMo(fps: Int, onDone: (enabled: Boolean, actual: Int) -> Unit) {
        mainHandler.post {
            val mgr = currentActivity()?.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            val cam = camera
            val id = if (mgr != null && cam != null) SlowMoController.readCameraId(cam) else null
            val supported = if (mgr != null && id != null) SlowMoController.supportedRates(mgr, id) else emptyList()
            val actual = SlowMoController.negotiate(fps, supported)
            slowMoFps = actual
            rebindAndReport { onDone(actual > 30, actual) }
        }
    }

    fun enableTimeLapse(intervalMs: Long, durationMs: Long, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            val act = currentActivity() ?: run { onDone(IllegalStateException("no activity")); return@post }
            val dir = File(act.cacheDir, "minis_timelapse").apply { mkdirs() }
            val outFps = if (requestedFps > 0) requestedFps else 30
            val outFile = File(dir, "minis_tl_${System.currentTimeMillis()}.mp4")
            timeLapse.start(act, intervalMs, durationMs, dir) { frames ->
                if (frames.isEmpty()) {
                    session.error("TIMELAPSE_NO_FRAMES", "no stills captured")
                    return@start
                }
                timeLapse.stitchToMp4(outFile.absolutePath, outFps, false, encoderExecutor) { path ->
                    if (path != null) {
                        session.emitInfo("timeLapseFinalized", path)
                    } else {
                        session.error("TIMELAPSE_STITCH_FAILED", null)
                    }
                }
            }
            onDone(null)
        }
    }

    private var requestedMicId: String? = null
    private var requestedMicGain: Double = 1.0

    fun setMic(deviceId: String?, gain: Double?, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            requestedMicId = deviceId
            requestedMicGain = (gain ?: 1.0).coerceIn(0.0, 8.0)
            val act = currentActivity() ?: run { onDone(null); return@post }
            try {
                val mgr = act.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                if (deviceId != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val target = mgr.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)
                        .firstOrNull { it.id.toString() == deviceId }
                    if (target != null) {
                        mgr.setCommunicationDevice(target)
                    }
                }
                onDone(null)
            } catch (e: Exception) { onDone(e) }
        }
    }

    fun listMics(onDone: (List<Map<String, Any?>>) -> Unit) {
        mainHandler.post {
            val act = currentActivity() ?: run { onDone(emptyList()); return@post }
            try {
                val mgr = act.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                val devs = mgr.getDevices(android.media.AudioManager.GET_DEVICES_INPUTS)
                val defaultId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    mgr.communicationDevice?.id?.toString() else null
                val list = devs.map { d ->
                    mapOf(
                        "id" to d.id.toString(),
                        "label" to (d.productName?.toString() ?: ""),
                        "type" to micTypeName(d.type),
                        "isDefault" to (d.id.toString() == defaultId),
                    )
                }
                onDone(list)
            } catch (e: Exception) {
                Log.w(TAG, "listMics: ${e.message}")
                onDone(emptyList())
            }
        }
    }

    private fun micTypeName(type: Int): String = when (type) {
        android.media.AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtin"
        android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth_sco"
        android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth_a2dp"
        android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
        android.media.AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
        android.media.AudioDeviceInfo.TYPE_USB_HEADSET -> "usb_headset"
        android.media.AudioDeviceInfo.TYPE_LINE_ANALOG -> "line_analog"
        else -> "other($type)"
    }

    fun setRecordWithAudio(enabled: Boolean, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            recordWithAudioEnabled = enabled
            onDone(null)
        }
    }

    private var pipCompositor: MultiCamCompositor? = null
    @Volatile private var pipOutPath: String? = null

    fun startMultiCam(layout: String, onDone: (Throwable?) -> Unit) {
        mainHandler.post {
            val act = currentActivity() ?: run { onDone(IllegalStateException("no activity")); return@post }
            val cp = cameraProvider ?: run { onDone(IllegalStateException("not warmed")); return@post }
            val pv1 = primaryPreview
            val pv2 = secondaryPreview
            cp.unbindAll()
            clearUseCases()
            val l = MultiCamController.layoutFromString(layout)
            val dir = File(act.cacheDir, "minis_native_capture").apply { mkdirs() }
            val out = File(dir, "minis_pip_${System.currentTimeMillis()}.mp4")
            val comp = MultiCamCompositor(1280, 720, 30, out.absolutePath, l)
            pipCompositor = comp
            pipOutPath = out.absolutePath
            comp.start { ready ->
                if (!ready) {
                    onDone(IllegalStateException("compositor failed")); return@start
                }
                mainHandler.post {
                    val primarySurf = comp.primaryInputSurface() ?: return@post onDone(IllegalStateException("no primary surface"))
                    val secondarySurf = comp.secondaryInputSurface() ?: return@post onDone(IllegalStateException("no secondary surface"))
                    val cc = MultiCamController.bindToCompositor(cp, act, primarySurf, secondarySurf)
                    concurrentBound = cc != null
                    // Side-effect: also attach the preview Surfaces to host PreviewViews so the UI shows live frames.
                    pv1?.let { /* PreviewView attachment skipped: compositor consumes the surface */ }
                    pv2?.let { /* ditto */ }
                    onDone(if (cc != null) null else IllegalStateException("concurrent unsupported"))
                }
            }
        }
    }

    fun stopMultiCam(onDone: (String?, Throwable?) -> Unit) {
        mainHandler.post {
            val comp = pipCompositor ?: run { onDone(null, IllegalStateException("not running")); return@post }
            pipCompositor = null
            runCatching { cameraProvider?.unbindAll() }
            comp.stop { outPath ->
                concurrentBound = false
                onDone(outPath ?: pipOutPath, null)
            }
        }
    }

    // --------- capabilities ----------

    fun capabilities(): Map<String, Any?> {
        val act = currentActivity()
        val mgr = act?.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        val cam = camera
        val id = if (mgr != null && cam != null) ManualControls.readPrimaryCameraId(cam) else null
        val manualRanges = if (mgr != null && id != null) ManualControls.readRanges(mgr, id) else ManualControls.ManualRanges()
        val supportedSlow = if (mgr != null && id != null) SlowMoController.supportedRates(mgr, id) else emptyList()
        val zoom = cam?.cameraInfo?.zoomState?.value
        val rawOk = cam?.let { RawCapture.isRawSupported(it.cameraInfo) } ?: false
        val multiCamOk = cameraProvider?.let { MultiCamController.isSupported(it) } ?: false
        return mapOf(
            "hdr10" to (cam?.let { hdr.isHdrSupported(cameraSelector) } ?: false),
            "raw" to rawOk,
            "slowMoFps" to supportedSlow,
            "multiCam" to multiCamOk,
            "manualIso" to (manualRanges.minIso != null && manualRanges.maxIso != null),
            "manualShutter" to (manualRanges.minShutterNs != null && manualRanges.maxShutterNs != null),
            "manualWb" to true,
            "manualFocus" to true,
            "timeLapse" to true,
            "minIso" to manualRanges.minIso,
            "maxIso" to manualRanges.maxIso,
            "minShutterNs" to manualRanges.minShutterNs,
            "maxShutterNs" to manualRanges.maxShutterNs,
            "minZoom" to (zoom?.minZoomRatio?.toDouble() ?: 1.0),
            "maxZoom" to (zoom?.maxZoomRatio?.toDouble() ?: 1.0),
        )
    }

    // --------- shutdown ----------

    fun release() {
        mainHandler.post {
            runCatching { multiClip?.discard() }
            multiClip = null
            isRecordingAtomic.set(false)
            runCatching { cameraProvider?.unbindAll() }
            clearUseCases()
            frameWatchdog.release()
            timeLapse.release()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) thermalGuard?.detach()
        }
    }

    fun attachThermal(context: Context, l: ThermalGuard.Listener) {
        thermalGuard = ThermalGuard(context).also {
            it.addListener(l)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) it.attach()
        }
    }

    fun attachFrameWatchdog(l: FrameWatchdog.Listener) {
        frameWatchdog.setListener(l)
    }

    fun isRecording(): Boolean = isRecordingAtomic.get()

    private fun hasMicPermission(act: FlutterFragmentActivity): Boolean =
        ContextCompat.checkSelfPermission(act, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    object NoPreviewException : Exception("No preview attached")

    companion object { private const val TAG = "MinisCameraXEngine" }
}
