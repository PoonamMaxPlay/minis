package com.loopit.minis.camera

import android.annotation.SuppressLint
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import java.util.concurrent.atomic.AtomicLong

/**
 * ImageAnalysis.Analyzer powered by MLKit Face Detection. Emits face rects on
 * the supplied [listener] at most every [minIntervalMs] (default ~66 ms / 15 Hz).
 *
 * Rect coordinates are normalised to the image frame (0..1) so the UI side can
 * rescale into preview coordinates without re-knowing the source resolution.
 */
class FaceAnalyzer(
    private val minIntervalMs: Long = 66,
    private val listener: CameraXEngine.AnalysisListener,
) : ImageAnalysis.Analyzer {

    private val detector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_NONE)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_NONE)
            .build()
    )
    private val lastEmit = AtomicLong(0)

    @Volatile
    var lastFaces: List<FloatArray> = emptyList()
        private set

    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(proxy: ImageProxy) {
        val now = System.currentTimeMillis()
        if (now - lastEmit.get() < minIntervalMs) { proxy.close(); return }
        val img = proxy.image ?: run { proxy.close(); return }
        val rotation = proxy.imageInfo.rotationDegrees
        val input = InputImage.fromMediaImage(img, rotation)
        val w = proxy.width.toFloat().coerceAtLeast(1f)
        val h = proxy.height.toFloat().coerceAtLeast(1f)

        detector.process(input)
            .addOnSuccessListener { faces ->
                lastEmit.set(System.currentTimeMillis())
                val maps = faces.map { f -> faceToMap(f, w, h) }
                lastFaces = faces.map { f ->
                    val r = f.boundingBox
                    floatArrayOf(r.left / w, r.top / h, r.width() / w, r.height() / h)
                }
                listener.onFaces(maps)
            }
            .addOnCompleteListener { proxy.close() }
    }

    private fun faceToMap(face: Face, w: Float, h: Float): Map<String, Any?> {
        val r = face.boundingBox
        return mapOf(
            "rect" to listOf(r.left / w, r.top / h, r.width() / w, r.height() / h),
            "confidence" to (face.smilingProbability ?: 1f),
            "id" to face.trackingId,
        )
    }
}
